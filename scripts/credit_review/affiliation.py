"""The org-affiliation verdicts every automatic user-facing step reads (RULE-org-affiliation,
data/credit-trust-system-fable-a1/org-affiliation-check-2026-10-16.md).

One reader for /var/lib/credit-trust/org-affiliation.json, shared by the take-back gate
(credit_retro.takeback) and the verify notes (credit_review.verify_notify):
``{user_id: {"verdict": <one of VERDICTS>, "evidence": [...]}}``. A file that cannot be read,
or any entry without a known verdict, raises ValueError: the caller sends or removes nothing.
A user with no verdict, or an AFFILIATED one, is never actioned automatically; a human
looks and uses the polite-contact variant.
"""

from __future__ import annotations

import json
import os
from typing import Any

PATH = os.environ.get("CREDIT_RETRO_ORG_AFFILIATION", "/var/lib/credit-trust/org-affiliation.json")
VERDICTS = frozenset({"none", "claimed_unverified", "contributor", "verified_org", "authenticated_domain"})
AFFILIATED = frozenset({"contributor", "verified_org", "authenticated_domain"})


def read(path: str | None = None) -> dict[str, dict[str, Any]]:
    """{user id (string): verdict object}; ValueError/OSError when it cannot be trusted."""
    with open(path or PATH, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise ValueError("not a user_id -> verdict object")
    for uid, v in doc.items():
        if not isinstance(v, dict) or v.get("verdict") not in VERDICTS:
            raise ValueError(f"user {uid}: no valid verdict")
    return {str(uid).strip(): v for uid, v in doc.items()}


def hold_reason(verdicts: dict[str, dict[str, Any]], user_id: Any) -> str | None:
    """Why this user must not be actioned automatically, or None."""
    v = verdicts.get(str(user_id).strip())
    if v is None:
        return "affiliation_unknown"
    return "org_affiliated" if v["verdict"] in AFFILIATED else None
