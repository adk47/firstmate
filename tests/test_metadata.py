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


def test_labels_missing_required_opp_raises_metadata_missing():
    """`opp` is required for a followup (a NEW contact has none yet): when
    absent the parser must treat it as missing, not produce None."""
    partial_labels = (
        "B2B - Ads",
        "muso-meta/kind-followup",
        "muso-meta/row-55",
        # opp missing
        "muso-meta/template-FU-01",
        "muso-meta/sender-a_at_muso.ai",
        "muso-meta/thread-1812f",
    )
    draft = _draft(labels=partial_labels, body_html="")
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


def test_labels_missing_required_sender_raises_metadata_missing():
    partial_labels = (
        "B2B - Ads",
        "muso-meta/kind-new",
        "muso-meta/row-55",
        "muso-meta/opp-xyz",
        "muso-meta/template-PrivateInvite",
        # sender missing
    )
    draft = _draft(labels=partial_labels, body_html="")
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


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


# --- NocoDB key shape (nocodb_id + row_id) and the legacy int row ---------

def _noco_labels(*extra, opp=False):
    base = [
        "B2B - Ads",
        "muso-meta/kind-new",
        "muso-meta/nocodb_id-2",
        "muso-meta/row_id-dangjf643",
        "muso-meta/template-PrivateInvite",
        "muso-meta/sender-a_at_muso.ai",
    ]
    if opp:
        base.append("muso-meta/opp-xyz")
    return tuple(base) + extra


def _expect(labels, body_html="", code=METADATA_MISSING):
    with pytest.raises(ValueError) as exc:
        parse_from_draft(_draft(labels=labels, body_html=body_html))
    assert exc.value.args[0] == code


def test_nocodb_shape_new_without_opp_parses():
    meta, _ = parse_from_draft(_draft(labels=_noco_labels()))
    assert (meta.nocodb_id, meta.row_id, meta.opp_id) == (2, "dangjf643", None)
    assert meta.sheet_row_id is None
    assert meta.kind is Kind.NEW


def test_nocodb_shape_json_agrees_and_disagrees():
    js = {"kind": "new", "nocodb_id": 2, "row_id": "dangjf643", "opp_id": None,
          "template": "PrivateInvite", "sender": "a@muso.ai",
          "original_thread_id": None}
    meta, warnings = parse_from_draft(
        _draft(labels=_noco_labels(), body_html=_json_comment(js)))
    assert meta.nocodb_id == 2 and warnings == []
    _expect(_noco_labels(), _json_comment({**js, "row_id": "other999"}),
            METADATA_LABEL_DISAGREE)
    legacy_json = {k: v for k, v in js.items() if k not in ("nocodb_id", "row_id")}
    legacy_json["sheet_row_id"] = 2
    _expect(_noco_labels(), _json_comment(legacy_json), METADATA_LABEL_DISAGREE)


def test_legacy_non_digit_row_is_metadata_missing_not_int_error():
    _expect(("B2B - Ads", "muso-meta/kind-new", "muso-meta/row-avedjs586",
             "muso-meta/opp-xyz", "muso-meta/template-T", "muso-meta/sender-a_at_muso.ai"))


def test_legacy_int_row_new_without_opp_still_parses():
    meta, _ = parse_from_draft(_draft(labels=(
        "B2B - Ads", "muso-meta/kind-new", "muso-meta/row-1234",
        "muso-meta/template-T", "muso-meta/sender-a_at_muso.ai")))
    assert (meta.sheet_row_id, meta.nocodb_id, meta.row_id) == (1234, None, None)


def test_both_key_shapes_present_disagree():
    _expect(_noco_labels("muso-meta/row-1234"), code=METADATA_LABEL_DISAGREE)


@pytest.mark.parametrize("bad", [
    ("muso-meta/nocodb_id-x2", "muso-meta/row_id-dangjf643"),
    ("muso-meta/nocodb_id-2",),  # no row_id
])
def test_nocodb_shape_malformed_is_metadata_missing(bad):
    _expect(("B2B - Ads", "muso-meta/kind-new", *bad,
             "muso-meta/template-T", "muso-meta/sender-a_at_muso.ai"))


def test_nocodb_followup_requires_opp_and_thread():
    base = ("B2B - Ads", "muso-meta/kind-followup", "muso-meta/nocodb_id-2",
            "muso-meta/row_id-dangjf643", "muso-meta/template-FU-01",
            "muso-meta/sender-a_at_muso.ai")
    _expect(base + ("muso-meta/thread-t1",))  # no opp
    _expect(base + ("muso-meta/opp-abc",))  # no thread
    meta, _ = parse_from_draft(_draft(labels=base + (
        "muso-meta/opp-abc", "muso-meta/thread-t1")))
    assert (meta.opp_id, meta.original_thread_id) == ("abc", "t1")
