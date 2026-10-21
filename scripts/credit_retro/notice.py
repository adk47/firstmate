"""The take-back notice: every removed role tells its user, at removal time.

Captain requirement (via firstmate 012, 2026-10-16): every take-back sends the user a
short, polite message saying which credit and role, why (who the public credits name, with
the link), and how to dispute it by replying with a document. It is sent when the removal
executes, never before.

The copy is FIXED (docs/credit-verification/retro-drafts/takeback-notice.md). The send goes
through Caroline's deterministic Intercom gate, scripts/intercom-verify-request.sh, campaign
``takeback-notice``: that tool pins the posting identity, resolves the recipient from the
ACCOUNT email, HTML-escapes the structured fields, runs the leak check and records every
send in its ledger. This module only builds the structured credits file, renders the
preview for review, and calls the tool. It never posts anything itself.

``apply`` validates every notice through the tool (``--validate``) BEFORE the execute: no
removal without its message. A user whose notice the tool would defer today (exit 3, one
message per user per day) has their whole set withheld this run (``notice_would_defer``); it
stays approved and is executed, with its notice, on a later day's run. A user whose notice
the tool refuses (exit 1, e.g. its leak check) has their whole set withheld
(``notice_refused``, firstmate 041) while every other user's set proceeds. A tool that
cannot run at all refuses the whole run.

The human who approved THIS copy and run is passed per run (``--notice-approved-by``); it is
never defaulted and is recorded in the ledger with every notice.
"""

from __future__ import annotations

import json
import os
import string
import subprocess
import tempfile
from collections import defaultdict
from typing import Any, Protocol

from .takeback import evidence_label

CAMPAIGN = "takeback-notice"
DEFAULT_SCRIPT = "/opt/hydra/scripts/intercom-verify-request.sh"
MAX_LISTED = 25
_ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)

SUBJECT_ONE = 'About your {role} credit on "{track_title}"'
SUBJECT_MANY = "About {n} of your credits on Muso"
INTRO_ONE = ('The public credits for "{track_title}" by {artist_name} name {other_names} for {role} '
             "({cite}), so we have removed the {role} credit from your profile.")
INTRO_MANY = "The public credits name someone else for these roles, so we have removed them from your profile:"
LINE = '- {role} on "{track_title}" by {artist_name}: {other_names} ({cite})'
BODY = """Hi {first_name},

I'm Caroline from Muso support. {intro}
{lines}
If you did this work, reply to this message with one document that shows it, for example an invoice, a work order, or an email from the artist, label or studio that names the track and your role. If the document checks out, we will put the credit back. Your other credits are not affected.

Thank you,

Caroline
Muso Support
"""


def _names(c: dict[str, Any]) -> str:
    names = [n for n in c.get("other_names") or [] if n]
    if len(names) <= 1:
        return names[0] if names else "another person"
    return ", ".join(names[:-1]) + " and " + names[-1]


def cite(c: dict[str, Any]) -> str:
    """The evidence as the user reads it: ``<source>: <url>``, plus ``; also named in <page>``
    when the row has a corroborating page (Fable v3: a press article is never called a
    "public credits page"; the removal rests on the DSP credit, the article only corroborates)."""
    out = f"{c['evidence_source']}: {c['evidence_url']}"
    return out + (f"; also named in {c['corroboration_url']}" if c.get("corroboration_url") else "")


def notice_credit(row: dict[str, Any]) -> dict[str, Any]:
    """The structured fields of one removed role (ids, the names quoted in the recorded
    evidence and the URL only)."""
    ev = row["evidence"]
    return {"request_id": row["request_id"], "profile_id": row["profile_id"], "track_id": row["track_id"],
            "role": row["role"], "track_title": row.get("track_title") or "", "artist_name": row.get("artist") or "",
            "other_names": list(ev["names"]),
            "evidence_url": row["evidence_url"], "evidence_source": evidence_label(row),
            "corroboration_url": ev.get("corroboration") or ""}


def lines_of(credits: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """One line per track title + artist + role: two requests for the same credit are one line.
    Matching lowercases ASCII letters only (the send gate's jq ascii_downcase), so "Café" and
    "CAFÉ" stay two lines here exactly as they do in the message that is sent."""
    seen: dict[tuple[str, str, str], dict[str, Any]] = {}
    for c in credits:
        seen.setdefault(tuple(c[k].translate(_ASCII_LOWER) for k in ("track_title", "artist_name", "role")), c)
    return list(seen.values())


def render(first_name: str | None, credits: list[dict[str, Any]]) -> tuple[str, str]:
    """Preview of the fixed copy (the send tool renders the same template)."""
    fname = (first_name or "").strip() or "there"
    credits = lines_of(credits)
    shown = credits[:MAX_LISTED]
    if len(credits) == 1:
        c = credits[0]
        subject = SUBJECT_ONE.format(**c)
        intro = INTRO_ONE.format(role=c["role"], track_title=c["track_title"], artist_name=c["artist_name"],
                                 other_names=_names(c), cite=cite(c))
        lines = ""
    else:
        subject = SUBJECT_MANY.format(n=len(credits))
        intro = INTRO_MANY
        lines = "\n".join(LINE.format(role=c["role"], track_title=c["track_title"], artist_name=c["artist_name"],
                                      other_names=_names(c), cite=cite(c))
                          for c in shown) + "\n"
        if len(credits) > len(shown):
            lines += f"- and {len(credits) - len(shown)} more\n"
    return subject, BODY.format(first_name=fname, intro=intro, lines=lines)


def credits_file(user: dict[str, Any], credits: list[dict[str, Any]]) -> dict[str, Any]:
    return {"campaign": CAMPAIGN,
            "user": {"email": user.get("email"), "id": str(user.get("id") or ""),
                     "auth_id": str(user.get("auth_id") or ""),   # the gate matches external_id to this
                     "first_name": user.get("first_name")},
            "credits": credits}


class Sender(Protocol):
    approved_by: str

    def validate(self, payload: dict[str, Any]) -> tuple[str, str]: ...
    def send(self, payload: dict[str, Any]) -> tuple[str, str]: ...


class ScriptSender:
    """Calls Caroline's gate. Exit codes (intercom-verify-request.sh): 0 posted, 1 refusal,
    2 usage/environment, 3 deferred (already messaged today), 4 post failed/unverified.
    ``validate`` answers ``valid`` / ``deferred`` / ``refused`` (exit 1: the gate refused THIS
    notice, e.g. its leak check on a title) / ``unavailable`` (the gate could not run: missing,
    usage/environment, hung); ``send`` answers ``sent`` / ``deferred`` / ``failed``. A hung or
    unrunnable call is never an exception."""

    def __init__(self, script: str | None = None, *, approved_by: str, timeout: int = 120):
        if not approved_by:
            raise SystemExit("--notice-approved-by <Slack user id> is required: the human who approved this "
                             "take-back notice copy and run")
        self.script = script or os.environ.get("CREDIT_RETRO_NOTICE_SCRIPT", DEFAULT_SCRIPT)
        self.approved_by = approved_by
        self.timeout = timeout

    def _run(self, payload: dict[str, Any], extra: list[str]) -> subprocess.CompletedProcess:
        if not os.path.exists(self.script):
            return subprocess.CompletedProcess([], 2, "", f"{self.script} not found")
        fd, path = tempfile.mkstemp(prefix="takeback-notice-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, ensure_ascii=False)
            argv = ["bash", self.script, "send", "--campaign", CAMPAIGN, "--credits-file", path,
                    "--approved-by", self.approved_by, *extra]
            try:
                return subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout, check=False)
            except (subprocess.TimeoutExpired, OSError) as exc:
                return subprocess.CompletedProcess(argv, 4, "", f"send gate did not complete: {exc}")
        finally:
            os.unlink(path)

    def validate(self, payload: dict[str, Any]) -> tuple[str, str]:
        proc = self._run(payload, ["--validate"])
        verdict = {0: "valid", 1: "refused", 3: "deferred"}.get(proc.returncode, "unavailable")
        return verdict, (proc.stdout if verdict == "valid" else proc.stderr or proc.stdout).strip()[:300]

    def send(self, payload: dict[str, Any]) -> tuple[str, str]:
        proc = self._run(payload, [])
        outcome = {0: "sent", 3: "deferred"}.get(proc.returncode, "failed")
        return outcome, (proc.stdout if outcome == "sent" else proc.stderr or proc.stdout).strip()[-300:]


def by_user(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        out[str(r["user_id"])].append(r)
    return out


def preview(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Render every user's notice for review (no send, no email needed)."""
    out = []
    for uid, rs in sorted(by_user(rows).items()):
        credits = [notice_credit(r) for r in rs]
        subject, body = render(None, credits)
        out.append({"user_id": uid, "subject": subject, "body": body, "credits": credits})
    return out
