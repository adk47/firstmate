"""Parse draft metadata from Gmail labels (primary) and JSON HTML
comment (fallback). See design spec §1 for reconciliation rules.
"""
from __future__ import annotations

import json
import re
from typing import Optional

from .config import META_LABEL_PREFIX
from .types import Draft, Kind, Metadata

METADATA_MISSING = "METADATA_MISSING"
METADATA_LABEL_DISAGREE = "METADATA_LABEL_DISAGREE"

_COMMENT_RE = re.compile(r"<!--\s*muso-outreach:v1\s+(\{.*?\})\s*-->", re.DOTALL)
# Label format: "muso-meta/<key>-<value>". Values may contain "-"; key does not.
_LABEL_RE = re.compile(rf"^{re.escape(META_LABEL_PREFIX)}([a-z_]+)-(.+)$")


def _decode_label_email(value: str) -> str:
    """Reverse the '@' → '_at_' replacement used when building labels."""
    return value.replace("_at_", "@")


_DIGITS_RE = re.compile(r"[0-9]+")


def _parse_labels(labels: tuple[str, ...]) -> Optional[dict]:
    """Return the label fields, None when required labels are missing or
    malformed (METADATA_MISSING), and raise METADATA_LABEL_DISAGREE when
    the NocoDB and legacy key shapes are both present."""
    kv: dict = {}
    for label in labels:
        m = _LABEL_RE.match(label)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        kv[key] = value
    if any(k not in kv for k in ("kind", "template", "sender")):
        return None
    # opp is required for followups only: a NEW contact has no GHL opp at
    # draft time (ghl-sync creates it after the send).
    if kv["kind"] == "followup" and ("thread" not in kv or "opp" not in kv):
        return None
    if "nocodb_id" in kv and "row" in kv:
        raise ValueError(METADATA_LABEL_DISAGREE)
    nocodb_id = row_id = sheet_row_id = None
    if "nocodb_id" in kv:
        if not _DIGITS_RE.fullmatch(kv["nocodb_id"]) or not kv.get("row_id"):
            return None
        nocodb_id, row_id = int(kv["nocodb_id"]), kv["row_id"]
    elif "row" in kv:
        if not _DIGITS_RE.fullmatch(kv["row"]):
            return None
        sheet_row_id = int(kv["row"])
    else:
        return None
    return {
        "kind": kv["kind"],
        "nocodb_id": nocodb_id,
        "row_id": row_id,
        "sheet_row_id": sheet_row_id,
        "opp_id": kv.get("opp"),
        "template": kv["template"],
        "sender": _decode_label_email(kv["sender"]),
        "original_thread_id": kv.get("thread"),
    }


def _parse_json_comment(body_html: str) -> Optional[dict]:
    m = _COMMENT_RE.search(body_html or "")
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return None


def _agree(labels: dict, js: dict) -> bool:
    # JSON may include override_reason / cc_allowlist / bcc_allowlist that
    # labels do not carry. Those are compared only if present in both.
    # Compare the key fields of the shape the labels use.
    key_fields = (("nocodb_id", "row_id") if labels.get("nocodb_id") is not None
                  else ("sheet_row_id",))
    for key in ("kind", *key_fields, "opp_id", "template",
                "sender", "original_thread_id"):
        if labels.get(key) != js.get(key):
            return False
    return True


def _build(labels: dict, js: Optional[dict]) -> Metadata:
    kind = Kind(labels["kind"])
    extras = js or {}
    cc = tuple(extras.get("cc_allowlist") or ())
    bcc = tuple(extras.get("bcc_allowlist") or ())
    return Metadata(
        kind=kind,
        nocodb_id=labels["nocodb_id"],
        row_id=labels["row_id"],
        sheet_row_id=labels["sheet_row_id"],
        opp_id=labels["opp_id"],
        template=labels["template"],
        sender=labels["sender"],
        original_thread_id=labels["original_thread_id"] if kind is Kind.FOLLOWUP else None,
        override_reason=extras.get("override_reason"),
        cc_allowlist=cc,
        bcc_allowlist=bcc,
    )


def parse_from_draft(draft: Draft) -> tuple[Metadata, list[str]]:
    """Return (metadata, warnings). Raise ValueError(code) on failure.

    Codes: METADATA_MISSING, METADATA_LABEL_DISAGREE.
    """
    labels = _parse_labels(draft.labels)
    js = _parse_json_comment(draft.body_html)
    warnings: list[str] = []

    if labels is None:
        raise ValueError(METADATA_MISSING)

    if js is not None and not _agree(labels, js):
        raise ValueError(METADATA_LABEL_DISAGREE)

    if js is None:
        warnings.append(
            "JSON metadata missing from draft body (labels present). "
            "This usually means the draft body was edited in Gmail. "
            "Proceeding from labels."
        )

    return _build(labels, js), warnings
