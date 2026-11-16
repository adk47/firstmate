"""F9 challenge codes (proof-loop lead 092/093, captain-1028-213x/214x): for `need =
distributor_dashboard_with_code`, the L11c ask carries a code we issue; the customer's next screenshot of their
live distributor / DSP dashboard must show it. A code in the screenshot proves the screen is live, recent and the
account holder's - the F9 anchor class.

  issue    when h2 SENDS that ask (`credit-doc-verify.py challenge issue --request ID`): one active code per
           request (an unexpired, unconsumed code is returned again, never a second one), valid 7 days.
  verify   by the reader, for the next document filed for that request: `xc_challenge` POSITIVE only when the
           document was received inside the code's window, by the request's own account, and the code is shown
           in one of the TWO places the reader looks:
             document    the document's own text (the find box in the screenshot: what the ask asks for);
             reply_text  what the customer typed alongside it (`proof_intake.reply_text_json`), in a message
                         that is ITSELF inside the code's window, and only for a document that is BOTH a
                         dashboard screenshot and supports the request on its own merits (`reply_ok`). A
                         typed code names no document, so without that it would be used up by whichever
                         attachment was read first, and the right screenshot would then be told the code was
                         already used. A typed code is a possession and freshness signal, never document
                         evidence: it confirms no F9 anchor by itself (see `gate.f9_anchor`) and the reader
                         does not consume the code on it, so a corrected screenshot showing the same code can
                         still verify the credit.
           The detail says which (`where`); a typed code the document could not bind is recorded as
           `seen_unbound`; the code itself is never recorded. Our own ask carries the code, so a code that
           appears only as that ask quoted back (a reply to our email, a screenshot of the chat) is not shown
           (`shown`). Expired / missing / before issue / another account -> WEAK with why (the document is
           simply unverifiable again; never a hold, never forged).

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
# The ask's own words on each side of the code, normalized as `_norm` does (the sender's `proof_need_line`:
# "... type this code in the find box: <code>, and take one screenshot ..."). A test holds these to that
# line of the sender: a change of the ask copy that moves them fails there, not silently here.
ASK_BEFORE = "TYPETHISCODEINTHEFINDBOX"
ASK_AFTER = "ANDTAKEONESCREENSHOT"
DOCUMENT, REPLY_TEXT = "document", "reply_text"


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


def shown(code: str, text: str | None) -> bool:
    """The code appears in `text` somewhere other than our own ask quoted back. Each occurrence is judged on
    its own: one that sits where the ask puts it (the ask's words directly before or after) is the ask, any
    other is the customer's."""
    body = _norm(text or "")
    at = body.find(code)
    while at >= 0:
        if not (body[:at].endswith(ASK_BEFORE) or body.startswith(ASK_AFTER, at + len(code))):
            return True
        at = body.find(code, at + 1)
    return False


def check(text: str | None, challenges: list[dict[str, Any]], *, user_id: int | None,
          received_at: str | None, consumer: str | None = None,
          reply: list[dict[str, str]] | None = None, reply_ok: bool = True) -> xc.Check | None:
    """None when no code was ever issued for this request (no step). Otherwise POSITIVE for the first
    challenge the document satisfies, else WEAK with why. A code is ONE use (QA #1476): once consumed by a
    filing (`consumer`, 'intake:<id>') it confirms only that same filing again (its other roles), never another.
    Only a code SHOWN IN THE DOCUMENT is consumed (`where` DOCUMENT); a typed one is never, see above.

    `reply` is what the customer typed alongside the document, [{at, text}]. It never moves the window: the
    DOCUMENT must be inside it either way, and a typed code counts only from a message that is inside it too.
    `reply_ok` False = this document may not be bound to a typed code: it is not a dashboard screenshot, or
    it does not support the request on its own merits (see the module docstring)."""
    if not challenges:
        return None
    got = _ts(received_at)
    typed = [(t, str(p.get("text") or "")) for p in (reply or []) for t in [_ts(p.get("at"))]]
    whys = []
    unbound = False
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
        detail = {"challenge_id": ch["id"], "issued_at": ch["issued_at"], "expires_at": ch["expires_at"],
                  "received_at": received_at, "anchor_class": "F9"}
        if shown(ch["code"], text):
            return xc.Check("xc_challenge", xc.POSITIVE, {**detail, "where": DOCUMENT})
        said = [t for t, words in typed if shown(ch["code"], words)]
        inside = sorted(t for t in said if t is not None and issued <= t <= expires)
        if inside and reply_ok:
            return xc.Check("xc_challenge", xc.POSITIVE,
                            {**detail, "where": REPLY_TEXT, "typed_at": inside[0].strftime("%Y-%m-%dT%H:%M:%SZ")})
        unbound = unbound or bool(said)
        whys.append("the document does not show the code")
        if inside:
            whys.append("the code was typed in the message, and this document does not support the request")
        elif said:
            whys.append("the code was typed in a message outside the code's window")
    detail = {"why": sorted(set(whys)), "challenges": len(challenges), "reply_messages": len(typed)}
    if unbound:
        detail["seen_unbound"] = True
    return xc.Check("xc_challenge", xc.WEAK, detail)


def now_utc() -> datetime:
    return datetime.now(timezone.utc)
