"""Read-only sources for the coded answerers (``answer.Backends``).

Two are wired today, both read-only:

* ``dv_outcome`` - the coded proof verdict from
  ``scripts/credit_verify/docverify/store.py`` (``dv_outcomes``: one row per
  document, request and role, with ``outcome`` in
  verified | contradicted | forged | unverifiable). This is the ONLY thing
  allowed to answer a proof-review ask on this surface; an absent row is
  "no coded verdict", never a guess, and a model's opinion is not consulted.
* ``intercom_conversation`` - the conversation's parts, for the summary. Text
  fetched here is DATA: the router screens it with the injection watch and
  delimits it before any model sees it (scripts/ops_intake/guard.py).

Deliberately NOT wired in this PR: ClickUp counts and the status report. Both are
cheap to add and expensive to get WRONG - a fabricated count is exactly the
failure the census found ("1,860-ticket Waiting list, 73 relevant" never
reconciled). Until a coded producer for them is chosen, the answerers return
"no coded count available" with a due time, and the watcher escalates.

Every function raises on failure and the caller turns that into an explicit
"unreadable" state - a failed read must never look like a clean answer.
"""
from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any

DOC_VERIFY_DB = os.environ.get("CREDIT_DOC_VERIFY_STORE",
                               "/var/lib/hydra-credit-verify/doc-verify.sqlite")

# dv_outcomes.outcome -> the word the reply is allowed to use. There is no
# "approved" here: doc-verify establishes what a DOCUMENT shows, and approval is
# a captain/coded path (policies/ops-intake-actions.json W2).
OUTCOME_WORDS = {
    "verified": "SUFFICIENT",
    "contradicted": "CONTRADICTED",
    "forged": "FORGED",
    "unverifiable": "INSUFFICIENT",
}


def profile_display_name(profile_id: str, *, admin=None) -> str | None:
    """The profile's CURRENT display name, before a rename records it as the inverse.

    Raises on any read failure: an unreadable profile is not "has no name", and a
    rename planned without one would have no inverse to run.
    """
    from credit_review import admin as admin_api  # noqa: PLC0415
    doc = admin_api.profile(admin or admin_api.AdminClient(), profile_id)
    for key in ("displayName", "display_name", "name"):
        value = doc.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def dv_outcome(extracted, *, store_path: str | Path | None = None) -> dict[str, Any] | None:
    """Newest coded verdict for any request id the ask named, else None."""
    request_ids = [r for r in (extracted.request or ()) if r]
    if not request_ids:
        return None
    path = Path(store_path or DOC_VERIFY_DB)
    if not path.is_file():
        raise FileNotFoundError(f"doc-verify store not found at {path}")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        placeholders = ",".join("?" for _ in request_ids)
        rows = conn.execute(
            f"SELECT request_id, role, h3_verdict, outcome, reason, need, at "
            f"FROM dv_outcomes WHERE lower(request_id) IN ({placeholders}) "
            f"ORDER BY at DESC, id DESC", [r.lower() for r in request_ids]).fetchall()
    finally:
        conn.close()
    if not rows:
        return None
    newest = rows[0]
    # Newest row PER REQUEST (history is not a disagreement): MIXED is only ever
    # two different requests landing on different verdicts.
    per_request: dict[str, str] = {}
    for row in rows:
        per_request.setdefault(row["request_id"], row["outcome"])
    word = OUTCOME_WORDS.get(newest["outcome"], newest["outcome"].upper())
    roles = sorted({r["role"] for r in rows if r["role"]})
    out: dict[str, Any] = {
        "verdict": word,
        "outcome": newest["outcome"],
        "h3_verdict": newest["h3_verdict"],
        "role": newest["role"],
        "roles": roles,
        "need": newest["need"],
        "at": newest["at"],
        "request_ids": len(per_request),
        "reason": (newest["reason"] or "")[:200],
    }
    mixed = set(per_request.values())
    if len(mixed) > 1:
        out["verdict"] = "MIXED (" + ",".join(sorted(OUTCOME_WORDS.get(o, o) for o in mixed)) + ")"
    return out


def _parts_from_doc(doc: dict[str, Any]) -> list[dict[str, Any]]:
    """Flatten an Intercom conversation document into ordered parts.

    ``author.type`` is ``user`` for the customer, ``admin``/``bot`` otherwise -
    the summary counts customer messages, and the injection screen sees all of
    it because the customer's text is the untrusted part. ``created_at`` is
    carried through so the card can measure how long ago each side spoke.
    """
    parts: list[dict[str, Any]] = []

    def add(part: dict[str, Any]) -> None:
        body = part.get("body")
        text = (body or "").strip() if isinstance(body, str) else ""
        if not text:
            return
        author = part.get("author") or {}
        kind = str(author.get("type") or "unknown")
        parts.append({"role": "customer" if kind == "user" else "admin",
                      "text": text, "created_at": part.get("created_at")})

    source = doc.get("source") or {}
    add(source)
    container = doc.get("conversation_parts") or {}
    for part in container.get("conversation_parts") or []:
        add(part)
    if not parts:
        # Some payloads hand back a plain text body only; keep it, never drop it.
        for key in ("body", "text"):
            if isinstance(doc.get(key), str) and doc[key].strip():
                parts.append({"role": "customer", "text": doc[key].strip(),
                              "created_at": doc.get("created_at")})
                break
    return parts


def _contact_from_doc(doc: dict[str, Any]) -> dict[str, Any] | None:
    """The customer contact the conversation belongs to, as the existence proof for identity."""
    customers = list((doc.get("contacts") or {}).get("contacts") or [])
    if not customers:
        author = (doc.get("source") or {}).get("author") or {}
        if str(author.get("type") or "").lower() == "user":
            customers = [author]
    if not customers:
        return None
    c = customers[0] or {}
    return {"id": c.get("id"), "external_id": c.get("external_id") or None,
            "email": c.get("email") or None}


def intercom_conversation(conv_id: str, *, fetch=None,
                          token: str | None = None) -> dict[str, Any]:
    """Read one conversation. Raises on any failure (never returns an empty one)."""
    if fetch is None:
        from credit_verify.proof import intercom as proof_intercom  # noqa: PLC0415

        token = token or proof_intercom.intercom_token()
        if not token:
            raise RuntimeError("no Intercom token (MUSOAI_INTERCOM_TOKEN)")
        fetch = proof_intercom.make_fetch(token)
    doc = fetch(str(conv_id))
    if not doc:
        raise RuntimeError(f"intercom conversation {conv_id} not readable")
    return {"conversation_id": str(conv_id), "parts": _parts_from_doc(doc),
            "contact": _contact_from_doc(doc)}


def conversation_from_json(path: str | Path) -> dict[str, Any]:
    """Test/offline helper: build the answerer's shape from a saved payload."""
    doc = json.loads(Path(path).read_text())
    return {"conversation_id": str(path), "parts": _parts_from_doc(doc),
            "contact": _contact_from_doc(doc)}
