#!/usr/bin/env python3
"""Email -> the Intercom contact that is THIS account, by the r5 rules and nothing weaker.

The identity gate is never loosened for a status line. We look up the account's confirmed core
email in Intercom, take the contacts' `external_id`s, and ask the ONE resolver
(`scripts/credit_review/identity_resolver.py`) whether exactly one account owns them — the
professional id, the Auth0 subject, or a processed profile the account holds. Any other answer
(no contact, no owner, two owners, a reverted claim elsewhere, a resolver error) means **there
is no Intercom route for this user**, and the driver falls to the email rung instead.

Never a name match, never a "the only lead with that email", never a fuzzy search.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Any, Callable

INTERCOM = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"


@dataclass
class Contact:
    contact_id: str = ""
    external_ids: tuple[str, ...] = ()
    why: str = ""
    # Set ONLY when we could not find out whether this account has an Intercom contact (a search
    # that timed out, a resolver that raised). It is NOT the same answer as "this account has no
    # contact": the email rung exists for users we KNOW have no Intercom identity, so a lookup we
    # could not complete must hold that rung rather than route around a contact-specific opt-out.
    lookup_error: str = ""


def search_contacts(email: str) -> list[dict[str, Any]]:
    """Contacts whose email equals `email` (an exact operator search, not a fuzzy match)."""
    import json
    import urllib.error
    import urllib.request

    tok = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not tok:
        raise RuntimeError("no Intercom token")
    body = {"query": {"field": "email", "operator": "=", "value": email}, "pagination": {"per_page": 50}}
    req = urllib.request.Request(f"{INTERCOM}/contacts/search", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {tok}", "Accept": "application/json",
                                          "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            ans = json.load(r)
    except (urllib.error.URLError, ValueError) as exc:
        raise RuntimeError(f"intercom contact search: {type(exc).__name__}") from exc
    return list(ans.get("data") or [])


def contact_for(email: str, user_id: str, *, query: Callable[[str], list[list[str]]],
                finder: Callable[[str], list[dict[str, Any]]] = search_contacts) -> Contact:
    """The contact that resolves to `user_id`, or a `why` explaining why there is none."""
    email = (email or "").strip().lower()
    if not email or "@" not in email:
        return Contact(why="no confirmed email on the account")
    try:
        found = finder(email)
    except RuntimeError as exc:
        return Contact(why=str(exc)[:120], lookup_error=str(exc)[:120])
    exts: list[str] = []
    for c in found:
        ext = str(c.get("external_id") or "").strip()
        if ext:
            exts.append(ext)
    if not exts:
        return Contact(why=f"{len(found)} contact(s) for that email, none with an external_id")
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    from credit_review import identity_resolver  # noqa: PLC0415

    try:
        got = identity_resolver.resolve(exts, query)
    except Exception as exc:              # noqa: BLE001 — any resolver failure is "no route", never a guess
        return Contact(why=f"resolver failed: {type(exc).__name__}",
                       lookup_error=f"resolver failed: {type(exc).__name__}")
    for c in found:
        ext = str(c.get("external_id") or "").strip()
        res = got.get(ext)
        if res is not None and res.account_id is not None and str(res.account_id) == str(user_id):
            return Contact(contact_id=str(c.get("id") or ""), external_ids=(ext,),
                           why=f"resolved by {res.matched_by}")
    why = "; ".join(f"{r.external_id}: {r.why}" for r in got.values() if r.why)[:160]
    return Contact(why=why or "no contact resolved to this account")
