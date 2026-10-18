"""The org-affiliation verdicts every automatic user-facing step reads (RULE-org-affiliation,
data/credit-trust-system-fable-a1/org-affiliation-check-2026-10-16.md).

One reader for /var/lib/credit-trust/org-affiliation.json, shared by the take-back gate
(credit_retro.takeback) and the verify notes (credit_review.verify_notify). The producer is
cmux-credit-system-lane (schema ``org-affiliation/v1``, firstmate 054)::

    {"schema": "org-affiliation/v1", "generated_at": "<tz-aware ISO>", ...,
     "users": {"<id>": {"verdict": <VERDICTS>, "coverage": "full" | "labels_only", "evidence": [...]}},
     "held":  {"<id>": {"reason": "..."}}}

The producer's rule, applied here: absent, held, or a file older than 2h = UNKNOWN = held.
A file that cannot be read, is not v1, is stale or dated in the future, or has any entry
without a known verdict raises ValueError: the caller sends or removes nothing at all.
Per user, nothing automatic happens unless the user has a verdict, is not held, was checked
with coverage ``full`` (all rows + login profile; ``labels_only`` is a partial check), and is
not AFFILIATED; otherwise a human looks and uses the polite-contact variant. A sender asks
for full coverage of the users it is about to act on by writing their ids to
``/var/lib/credit-trust/inputs/org-affiliation-priority-<lane>.json`` (``write_priority``).

The legacy flat shape ``{user_id: {verdict, evidence}}`` (pre-v1, tests) is still read; its
entries have no coverage and no stamp, so it is accepted only without either check.
"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

PATH = os.environ.get("CREDIT_RETRO_ORG_AFFILIATION", "/var/lib/credit-trust/org-affiliation.json")
PRIORITY_DIR = os.environ.get("CREDIT_TRUST_AFFILIATION_PRIORITY_DIR", "/var/lib/credit-trust/inputs")
SCHEMA = "org-affiliation/v1"
MAX_AGE = timedelta(hours=2)
MAX_SKEW = timedelta(minutes=5)
VERDICTS = frozenset({"none", "claimed_unverified", "contributor", "verified_org", "authenticated_domain"})
AFFILIATED = frozenset({"contributor", "verified_org", "authenticated_domain"})
FULL = "full"
_HELD = "__held__"


def _ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return ts if ts.tzinfo else None


def read(path: str | None = None, *, now: datetime | None = None) -> dict[str, dict[str, Any]]:
    """{user id (string): verdict object}; ValueError/OSError when it cannot be trusted. A held
    user maps to {"verdict": None, "held": reason}."""
    with open(path or PATH, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise ValueError("not a JSON object")
    if "schema" not in doc:  # legacy flat shape
        for uid, v in doc.items():
            if not isinstance(v, dict) or v.get("verdict") not in VERDICTS:
                raise ValueError(f"user {uid}: no valid verdict")
        return {str(uid).strip(): {**v, "coverage": FULL} for uid, v in doc.items()}
    if doc.get("schema") != SCHEMA:
        raise ValueError(f"schema {doc.get('schema')!r} is not {SCHEMA}")
    gen = _ts(doc.get("generated_at"))
    now = now or datetime.now(timezone.utc)
    if gen is None:
        raise ValueError("no readable timezone-aware generated_at")
    if now - gen > MAX_AGE:
        raise ValueError(f"older than {MAX_AGE} (generated {doc['generated_at']})")
    if gen - now > MAX_SKEW:
        raise ValueError(f"dated in the future ({doc['generated_at']})")
    users, held = doc.get("users"), doc.get("held", {})
    if not isinstance(users, dict) or not isinstance(held, dict):
        raise ValueError("users{} / held{} missing or not objects")
    out: dict[str, dict[str, Any]] = {}
    for uid, v in users.items():
        if not isinstance(v, dict) or v.get("verdict") not in VERDICTS:
            raise ValueError(f"user {uid}: no valid verdict")
        out[str(uid).strip()] = v
    for uid, v in held.items():
        out[str(uid).strip()] = {"verdict": None, _HELD: str((v or {}).get("reason") or "held") if isinstance(v, dict)
                                 else "held"}
    return out


def hold_reason(verdicts: dict[str, dict[str, Any]], user_id: Any) -> str | None:
    """Why this user must not be actioned automatically, or None."""
    v = verdicts.get(str(user_id).strip())
    if v is None:
        return "affiliation_unknown"
    if _HELD in v:
        return "affiliation_held"
    if v.get("coverage") != FULL:
        return "affiliation_partial_check"
    return "org_affiliated" if v["verdict"] in AFFILIATED else None


def write_priority(lane: str, user_ids: Iterable[Any], *, source: str, directory: str | None = None) -> str:
    """Ask the producer for a full check of the users this lane is about to act on
    (atomic replace of inputs/org-affiliation-priority-<lane>.json). Returns the path."""
    d = directory or PRIORITY_DIR
    ids = sorted({int(str(u).strip()) for u in user_ids if str(u).strip().isdigit()})
    path = os.path.join(d, f"org-affiliation-priority-{lane}.json")
    fd, tmp = tempfile.mkstemp(prefix=".org-affiliation-priority-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"source": source, "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       "user_ids": ids}, fh)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path
