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


def _parse_labels(labels: tuple[str, ...]) -> Optional[dict]:
    kv: dict = {}
    for label in labels:
        m = _LABEL_RE.match(label)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        kv[key] = value
    # "kind" is the sentinel — without it, labels are considered missing.
    if "kind" not in kv:
        return None
    # Normalize
    out = {
        "kind": kv["kind"],
        "sheet_row_id": int(kv["row"]) if "row" in kv else None,
        "opp_id": kv.get("opp"),
        "template": kv.get("template"),
        "sender": _decode_label_email(kv["sender"]) if "sender" in kv else None,
        "original_thread_id": kv.get("thread"),
    }
    return out


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
    for key in ("kind", "sheet_row_id", "opp_id", "template",
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
