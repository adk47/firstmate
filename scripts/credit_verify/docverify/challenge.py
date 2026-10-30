"""F9 challenge codes (proof-loop lead 092/093, captain-1028-213x/214x): for `need =
distributor_dashboard_with_code`, the L11c ask carries a code we issue; the customer's next screenshot of their
live distributor / DSP dashboard must show it. A code in the screenshot proves the screen is live, recent and the
account holder's - the F9 anchor class.

  issue    when h2 SENDS that ask (`credit-doc-verify.py challenge issue --request ID`): one active code per
           request (an unexpired, unconsumed code is returned again, never a second one), valid 7 days.
  verify   by the reader, for the next document filed for that request: `xc_challenge` POSITIVE only when the
           document was received inside the code's window, by the request's own account, and its text contains
           the code. Expired / missing / before issue / another account -> WEAK with why (the document is simply
           unverifiable again; never a hold, never forged).

Codes: 8 characters from an alphabet without the pairs OCR confuses (0/O, 1/I/L, 2/Z, 5/S, 8/B): 25^8 = 1.5e11.
"""
from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any

from . import crosscheck as xc

ALPHABET = "ACDEFGHJKMNPQRTUVWXY34679"
LENGTH = 8
VALID_DAYS = 7
_NON_ALNUM = re.compile(r"[^0-9A-Z]+")


def new_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))


def well_formed(code: str) -> bool:
    return len(code or "") == LENGTH and all(c in ALPHABET for c in code)


def _norm(text: str) -> str:
    """Uppercase, every non-alphanumeric dropped: OCR splits a code with spaces, dashes or line breaks."""
    return _NON_ALNUM.sub("", (text or "").upper())


def _ts(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")) if s else None
    except ValueError:
        return None


def expiry(issued_at: datetime) -> datetime:
    return issued_at + timedelta(days=VALID_DAYS)


def check(text: str | None, challenges: list[dict[str, Any]], *, user_id: int | None,
          received_at: str | None, consumer: str | None = None) -> xc.Check | None:
    """None when no code was ever issued for this request (no step). Otherwise POSITIVE for the first
    challenge the document satisfies, else WEAK with why. A code is ONE use (QA #1476): once consumed by a
    filing (`consumer`, 'intake:<id>') it confirms only that same filing again (its other roles), never another."""
    if not challenges:
        return None
    body = _norm(text or "")
    got = _ts(received_at)
    whys = []
    for ch in challenges:
        issued, expires = _ts(ch["issued_at"]), _ts(ch["expires_at"])
        if str(ch.get("consumed_by") or "").startswith("void:"):
            whys.append("the code was voided (its ask was not sent)")
            continue
        if ch.get("consumed_at") and (consumer is None or ch.get("consumed_by") != consumer):
            whys.append("the code was already used by another document")
            continue
        if ch.get("user_id") is not None and user_id is not None and int(ch["user_id"]) != int(user_id):
            whys.append("the code was issued to another account")
            continue
        if got is None or issued is None or expires is None:
            whys.append("no received time on the document")
            continue
        if got < issued:
            whys.append("the document was sent before the code was issued")
            continue
        if got > expires:
            whys.append(f"the code expired {ch['expires_at']}")
            continue
        if ch["code"] not in body:
            whys.append("the document does not show the code")
            continue
        return xc.Check("xc_challenge", xc.POSITIVE, {"challenge_id": ch["id"], "issued_at": ch["issued_at"],
                                                      "expires_at": ch["expires_at"], "received_at": received_at,
                                                      "anchor_class": "F9"})
    return xc.Check("xc_challenge", xc.WEAK, {"why": sorted(set(whys)), "challenges": len(challenges)})


def now_utc() -> datetime:
    return datetime.now(timezone.utc)
