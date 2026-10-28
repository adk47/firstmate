"""The ONLY customer-facing lines Caroline's actions may return: approved wording, verbatim.

No new copy (captain 23:30Z order). Each template is the exact text of a campaign already approved in
scripts/intercom-verify-request.sh, rendered with the same rules (jq `qt`, `andjoin`, `titles`, first
name). scripts/tests/test_caroline_actions.py reads the .sh and fails if any template here drifts.

  status-doc-received   firstmate 070  (def status_doc_received)       credit, our document review
  status-team-review    firstmate 070  (def status_team_review_noask)  credit, waiting on us
  claim-status          Fable claims-documentation-readiness-1023 r3 (def claim_status_note)

All three say "Nothing else is needed from you right now". policy.py therefore offers them only to a
user who owes nothing (captain 2026-10-27 12:55Z item 5). There is no approved merge, dispute or ask line
here on purpose: those stay a handoff until the captain approves wording.
"""

from __future__ import annotations

import re

MAX_TITLES = 3  # the gate's $maxl for status notes

TEMPLATES: dict[str, str] = {
    "status-doc-received": (
        "Hi {fn}, a quick update on your credit {req_s} for {titles}: we have the document you sent us, and our "
        "team is reviewing it. Nothing else is needed from you right now, and you'll see each credit on your "
        "profile as soon as it's approved."),
    "status-team-review": (
        "Hi {fn}, a quick update on your credit {req_s} for {titles}: they're with our team for review. Nothing "
        "else is needed from you right now."),
    "claim-status": (
        "Hi {fn}, a quick update on your claim on {profile_name}: it is with our team for review. Nothing else is "
        "needed from you right now, and we will message you here as soon as it has been checked."),
}

# The jq definition each template mirrors (for the parity test).
JQ_DEFS = {
    "status-doc-received": "status_doc_received",
    "status-team-review": "status_team_review_noask",
    "claim-status": "claim_status_note",
}

_QUOTED = re.compile(r"^[\"“”„«»'‘’‚].*[\"“”„«»'‘’‚]$")
# jq: test("^\\p{L}[\\p{L}'.-]{0,39}$") -- a letter, then letters or ' . - only.
_FIRST = re.compile(r"^[^\W\d_](?:[^\W\d_]|['.-]){0,39}$", re.UNICODE)


def qt(title: str) -> str:
    return title if _QUOTED.match(title) else f'"{title}"'


def andjoin(items: list[str]) -> str:
    if len(items) <= 1:
        return items[0] if items else ""
    return ", ".join(items[:-1]) + " and " + items[-1]


def titles(names: list[str], maxl: int = MAX_TITLES) -> str:
    shown = andjoin([qt(t) for t in names[:maxl]])
    return shown + (f" and {len(names) - maxl} more" if len(names) > maxl else "")


def first_name(full: str | None) -> str:
    """The gate's rule: the first word of the account name if it looks like a name, else "there"."""
    fn = (full or "").strip().split(" ")[0] if (full or "").strip() else ""
    return fn if fn and _FIRST.match(fn) else "there"


def render(line_id: str, *, full_name: str | None, track_titles: list[str] | None = None,
           profile_name: str | None = None) -> str:
    """Fill one approved template from server facts. Raises on a missing fact: never a half line."""
    if line_id not in TEMPLATES:
        raise ValueError(f"no approved line {line_id!r}")
    fn = first_name(full_name)
    if line_id == "claim-status":
        name = (profile_name or "").strip()
        if not name:
            raise ValueError("claim-status needs the catalog profile name")
        return TEMPLATES[line_id].format(fn=fn, profile_name=name)
    names = [t.strip() for t in (track_titles or []) if t and t.strip()]
    if not names:
        raise ValueError(f"{line_id} needs at least one track title")
    return TEMPLATES[line_id].format(fn=fn, req_s="request" if len(names) == 1 else "requests", titles=titles(names))
