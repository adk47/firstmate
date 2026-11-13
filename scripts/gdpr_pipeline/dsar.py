"""The GDPR / DSAR ladder: statutory clock, identity chain, request state and the messages owed.

PURE: no network, no store, no clock of its own (every function takes `now`). `run.py` feeds it register rows and
writes what it returns; `send.py` is the only code that sends, and it sends a ladder message only on a reviewer
verdict bound to the exact body (`copy_gate.py`).

What this module owns:

  clock     `due()` is the date we tell the requester. Art. 12(3): "without undue delay and in any event within one
            month of receipt of the request". We state the EARLIER of one calendar month and receipt + 30 days, so
            the stated date is never later than either reading. An extension moves it only when one is recorded.
  identity  Aaron's ruling of 2026-11-12, as three gates: (1) account control, (2) a tie between that requester and
            the page (a processed claim, or a verified sender on the page's own website host), (3) an authority
            document, asked for only where 1 and 2 do not settle it. A passport is never asked for: it proves the
            person, not that the page is theirs. `need()` is the ONE thing the requester still has to do.
  state     received -> identity_check -> in_progress -> responded -> closed. DERIVED from recorded facts on every
            run, never set by hand, so a request cannot reach `closed` without a recorded final response.
  ladder    at most one message owed per request per run: the acknowledgement (states the deadline and the need),
            a status update at the halfway point, and, past the deadline, a status update every 14 days until the
            final response. The final response for an erasure is the existing confirmation letter.
  alarm     `clock_rows()` names every statutory request inside 7 days of its date or past it.

Scope: the statutory classes only (`STATUTORY`). A legal threat or a takedown notice is not a data-subject request
and gets no ladder message (captain 2026-11-10: no legal letters).
"""
from __future__ import annotations

import calendar
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gdpr_pipeline import identity

STATUTORY = ("privacy_erasure", "privacy_access")
ALARM_DAYS = 7              # inside this many days of the date, the request is named to firstmate
QUIET_DAYS = 7              # never two unprompted messages inside this window
LATE_INTERVAL_DAYS = 14     # past the date: the next-contact promise each status update makes
LATE_LEAD_DAYS = 1          # ... and how far ahead of that promise the next one is sent
LATE_MIN_RUNWAY_DAYS = 3    # a held late update whose promised date is nearer than this is re-authored
ACK_MIN_RUNWAY_DAYS = 3     # an acknowledgement promises the answer by the date: not with less than this left
# Decisions of 2026-11-12 (firstmate inbox 004, data/gdpr-ai-handling-v1/report.md finding 5). Each number here is a
# promise a message makes, so changing one is a decision and not a tuning.
LATE_ANSWER_DAYS = 14       # a late request we need nothing for is told the date it gets its answer: this far out
EXTENSION_MIN_REQUESTS = 2  # Art. 12(3) "number of the requests": open statutory requests from the same requester
EXTENSION_MONTHS = 1        # how far the notice moves the date (the rule allows up to two further months)
EXTENSION_RULING = "firstmate-inbox-004/2026-11-12T07:09:30Z"      # the ruling that allows the notice at all;
#                     each request's own need is recorded with its own ruling id (`extension_need_ruling`)
BODY_MAX = 1800

RECEIVED, IDENTITY_CHECK, IN_PROGRESS, RESPONDED, CLOSED = (
    "received", "identity_check", "in_progress", "responded", "closed")
STATES = (RECEIVED, IDENTITY_CHECK, IN_PROGRESS, RESPONDED, CLOSED)
TERMINAL = (CLOSED,)

NEED_NONE, NEED_UNKNOWN, NEED_CLAIM_OR_AUTHORITY, NEED_LINK, NEED_AUTHORITY, NEED_ACCOUNT = (
    "none", "unknown", "claim_or_authority", "link", "authority", "account")
NEEDS = (NEED_NONE, NEED_UNKNOWN, NEED_CLAIM_OR_AUTHORITY, NEED_LINK, NEED_AUTHORITY, NEED_ACCOUNT)

KIND_ACK, KIND_STATUS, KIND_EXTENSION = "ack", "status", "extension"
KIND_ACCESS = "access"          # the cover message of an Art. 15 answer (gdpr_pipeline/access.py holds the copy)
ACCESS_VARIANT = "access_answer"
LATE_NO_DATE_VARIANT = "late_none_no_date"       # late, nothing needed, and no answer date we could keep
# Every kind this module can author. `send.deliver` refuses to send any of them without a reviewer verdict.
GATED_KINDS = (KIND_ACK, KIND_STATUS, KIND_EXTENSION, "denial", KIND_ACCESS)

COPY_PATH = Path(__file__).resolve().parents[2] / "policies" / "gdpr-dsar-copy.json"
SLOTS = ("received", "due", "next")

# How a page verdict reads as a tie between the requester and the page. A name match is not here on purpose.
TIE_OF_VERDICT = {
    identity.PASS_A: "claim",
    identity.PASS_D: "own_site",
}
# A page that is already off the site is NOT tied to anybody by that fact. For an erasure request it needs nothing more
# from the requester (there is nothing left to act on, so nothing to tie); for an access request it settles nothing.
MOOT_OF_VERDICT = {
    identity.ALREADY_HIDDEN: "hidden",
    identity.HIDDEN_PENDING: "hidden",
    identity.GONE: "gone",
}
NO_LINK = "no_link"         # only an 8-char id prefix is on file and the catalog has no single page for it
UNTIED_VERDICTS = (identity.ASK_IDENTITY, identity.ASK_AUTH, identity.ASK_LINK)

# The code backstop on our own sentences. The reviewer's lint has its own list; this one runs before a body is ever
# queued for review, so a variant that trips it is a build failure and not a held message.
BARRED_RE = re.compile(
    r"\b(fraud\w*|abus(?:e|ed|ive|ing)|cheat\w*|suspicious\w*|suspect(?:ed)?|flagged|scam\w*|fake[ds]?|forg(?:ed|ery)|"
    r"tamper\w*|manipulat\w*|bad faith|dishonest\w*|impersonat\w*|business day\w*|"
    r"we will delete|deleted on request|unlawful\w*|illegal\w*|breach\w*|violat\w*|backlog\w*|understaff\w*|"
    r"technical (?:issue|problem|fault)s?|high volume\w*)\b", re.I)
# An apology belongs in ONE place: the update to a request that is past its date. Anywhere else it reads as an
# admission nobody decided to make.
APOLOGY_RE = re.compile(r"\b(sorry|apologi[sz]e\w*)\b", re.I)


class CopyError(Exception):
    """The copy file is unreadable or a variant cannot be rendered. Never a message: nothing is authored."""


# ------------------------------------------------------------------------------------------------------ clock
def _parse(s: str) -> datetime:
    return datetime.strptime(s[:19].replace(" ", "T"), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def add_months(dt: datetime, n: int) -> datetime:
    """The same day `n` months on; the last day of that month when it has no such day (31 January -> 28 February)."""
    y, m = divmod(dt.month - 1 + n, 12)
    y, m = dt.year + y, m + 1
    return dt.replace(year=y, month=m, day=min(dt.day, calendar.monthrange(y, m)[1]))


def statutory_due(received_at: str) -> datetime:
    r = _parse(received_at)
    return min(add_months(r, 1), r + timedelta(days=30))


def extension_limit(received_at: str) -> datetime:
    """Art. 12(3): "may be extended by two further months". The furthest date an extension can reach."""
    return add_months(_parse(received_at), 3)


def due(row: dict) -> datetime:
    """The date the requester is owed an answer by. An extension counts only when one is recorded on the row, and
    never past the three-month limit; a malformed one is ignored rather than trusted."""
    base = statutory_due(row["received_at"])
    ext = row.get("extended_until") or ""
    if ext:
        try:
            return max(base, min(_parse(ext), extension_limit(row["received_at"])))
        except ValueError:
            return base
    return base


def human_date(dt: datetime) -> str:
    return f"{dt.day} {dt.strftime('%B %Y')}"


# --------------------------------------------------------------------------------------------------- identity
def gates(cls: str, account_id, account_how: str, representative: bool, page_verdicts: list[dict],
          pages_named: int, prefixes_read: bool = False) -> dict:
    """The three gates for one request, and the ONE thing still needed from the requester.

    `page_verdicts` is the per-page identity answer ({"id", "verdict"}); `pages_named` is how many pages the request
    names at all (a page whose read failed is named but has no usable verdict). `prefixes_read` says the catalog
    answered this run's id-prefix lookup: only then is an 8-char id that is still unresolved a FACT (no single page
    carries it, so the link has to come from the requester) and not a read that failed. Nothing here reads request
    text.

    Gate 2 passes only on a tie: the requesting account's processed claim, or the artist's own site. A page that is
    already hidden or gone ties nobody; it only stops needing anything for an erasure request.
    """
    g1 = account_id is not None
    ties: dict[str, str] = {}
    unknown = pages_named > len(page_verdicts)
    untied = no_link = False
    tied = 0
    for pv in page_verdicts:
        verdict = pv.get("verdict") or ""
        if verdict in TIE_OF_VERDICT:
            ties[pv["id"]] = TIE_OF_VERDICT[verdict]
            tied += 1
        elif verdict in MOOT_OF_VERDICT and cls == "privacy_erasure":
            ties[pv["id"]] = MOOT_OF_VERDICT[verdict]
        elif verdict in UNTIED_VERDICTS:
            ties[pv["id"]] = ""
            untied = True
        elif verdict == identity.UNKNOWN and len(pv["id"]) == 8 and prefixes_read:
            ties[pv["id"]] = NO_LINK
            no_link = True
        else:                       # a failed read, or a page a coded path cannot settle: not a pass, not an ask
            ties[pv["id"]] = "unknown"
            unknown = True
    if untied or no_link:
        tie_pass = False
    elif unknown or not tied:
        tie_pass = None             # nothing read, nothing named, or nothing left on the site to tie
    else:
        tie_pass = True

    if representative:
        need = NEED_AUTHORITY
    elif pages_named == 0:
        # An access request with no page is about the ACCOUNT's own data: account control is the whole question.
        need = (NEED_NONE if g1 else NEED_ACCOUNT) if cls == "privacy_access" else NEED_LINK
    elif no_link:
        need = NEED_LINK            # that letter asks for the link AND says how to connect the page
    elif untied:
        need = NEED_CLAIM_OR_AUTHORITY
    elif unknown:
        need = NEED_UNKNOWN
    else:
        need = NEED_NONE
    return {
        "v": 1,
        "account": {"pass": g1, "how": account_how if g1 else ""},
        "tie": {"pass": tie_pass, "pages": ties},
        # Gate 3 is asked for only where 1 and 2 do not settle it. No store records a document yet, so `on_file`
        # is always False: an authority document that arrives has no coded check, and the alarm names the request.
        "authority": {"needed": need in (NEED_AUTHORITY, NEED_CLAIM_OR_AUTHORITY), "on_file": False},
        "need": need,
    }


def need_of(row: dict) -> str:
    """The need recorded on the row; `unknown` when the row has never been through the gates."""
    n = (row.get("gates") or {}).get("need") or ""
    return n if n in NEEDS else NEED_UNKNOWN


# ------------------------------------------------------------------------------------------------------ state
FINAL_SLOTS = ("confirm", "access")      # the ledger slots whose `sent` row IS the final response


def final_response_at(row: dict, sends: list[dict] = ()) -> str:
    """When the final response was recorded, or ''. The ONLY fact that can take a request to `responded`.

    Read from the row's stamp AND the send ledger, like `contacted_at` and for the same reason: the ledger is the
    record of what left. Measured on the live register 2026-11-12: 7 open erasure requests carry a `sent` final
    confirmation in the ledger (reconciled from `unknown` after the writer's read-back) and no `confirmed_at`. By a
    stamp-only reading each was still open and was owed "we are late, and we are sorry", four of them with a date
    for an answer they already have. An interim confirmation (`confirm-interim`) is not a final response."""
    led = [s.get("at") or "" for s in sends if s.get("kind") in FINAL_SLOTS and s.get("state") == "sent"]
    return max([row.get("confirmed_at") or ""] + led)


def in_flight(sends: list[dict]) -> bool:
    return any(s.get("state") in ("sending", "unknown") for s in sends)


def contacted_at(row: dict, sends: list[dict] = ()) -> str:
    """The latest message we sent on this request, or ''.

    Read from the row's stamps AND the send ledger. The ledger is the record of what left; a stamp is a copy of it
    that can be missing (measured on the live register 2026-11-12: 24 open requests carry a `sent` ask in the ledger
    and no `ask_sent_at`, and every one of them was owed a first acknowledgement by a stamps-only reading)."""
    stamps = [row.get(c) or "" for c in ("ack_sent_at", "ask_sent_at", "status_sent_at", "interim_confirm_at",
                                         "confirmed_at")]
    return max(stamps + [s.get("at") or "" for s in sends if s.get("state") == "sent"])


def first_contact_made(row: dict, sends: list[dict]) -> bool:
    """Has this request already had its first message from us (an acknowledgement, or the older ask), or might it?

    A ledger row that is `sending` or `unknown` counts: a letter may be out, and a second first-message on top of it
    is the double contact the ledger exists to prevent. Such a row is named by the clock until someone resolves it."""
    if row.get("ack_sent_at") or row.get("ask_sent_at"):
        return True
    return any(s.get("kind") in (KIND_ACK, "ask", KIND_EXTENSION) and s.get("state") in ("sent", "sending", "unknown")
               for s in sends)


# The older identity ask (`copy.ASK`, `Run.asks`) beside the ladder, for a statutory request.
FALLBACK_HOURS = 24                      # how long a letter may wait in the gate's review queue before the older ask goes
CLOCK_UNREAD_HOURS = 26                  # the firstmate check reads every 5 min; a day and a bit unread is "not running"
NO_FIRST_MESSAGE_HOURS = 48              # a statutory request nobody has written to by then is named on the clock
FIRST_REPLY_HOURS = 24                   # the first message is due this long after the request arrived


def first_reply_due(row: dict) -> datetime:
    """The date the FIRST message on this request was due: `FIRST_REPLY_HOURS` after it arrived."""
    return _parse(row["received_at"]) + timedelta(hours=FIRST_REPLY_HOURS)


def send_dates(row: dict, sends: list[dict], sent_at: datetime) -> dict:
    """What a sent ladder message records against its row: the date it was due and the date it went.

    `sends` is the request's ledger BEFORE this message was claimed, so `first_message` says whether this is the
    first thing we ever sent on the request. A first message was due `FIRST_REPLY_HOURS` after arrival; every
    message is also recorded against the statutory date. Dates only: no name, address or body.
    """
    first = not (contacted_at(row, sends) or first_contact_made(row, sends))
    out = {"received_at": row["received_at"], "statutory_due_at": _iso(due(row)), "sent_at": _iso(sent_at),
           "first_message": first}
    if first:
        target = first_reply_due(row)
        out["first_reply_due_at"] = _iso(target)
        out["first_reply_late_hours"] = max(0.0, round((sent_at - target).total_seconds() / 3600, 1))
    return out

# What the ladder has for ONE request, read from that request's own rows. The four in the middle are the copy gate's
# own answers (`copy_gate`: approved | pending | refused | error) for a letter that is authored and not out.
LETTER_SENT, LETTER_APPROVED, LETTER_PENDING = "sent", "approved", "pending"
LETTER_REFUSED, LETTER_ERROR, LETTER_MISSING, LETTER_NONE = "refused", "error", "missing", ""
# Does the older ask stand down? EVERY value the ladder can have for a request is a key here, and a test holds the
# table to `ladder_letter`'s range, so a new value cannot be added without deciding it. The ask stands down only
# where the gate HOLDS a letter that is going to this request: one it approved (or that is out), or one it has in its
# review queue, and that one for no longer than FALLBACK_HOURS. Everywhere else the gate holds nothing for the
# request, so the older ask goes at once: a refusal sends nothing, a gate that could not answer has no letter, and a
# letter the gate was never asked about is not in anybody's queue.
OLDER_ASK_STANDS_DOWN = {
    LETTER_SENT: True,        # the ladder has written, or may have: a second first message is the double contact
    LETTER_APPROVED: True,    # the gate approved these exact bytes: the letter goes on this send
    LETTER_PENDING: True,     # in the review queue: wait for the verdict, FALLBACK_HOURS at most (see `older_ask`)
    LETTER_REFUSED: False,    # the reviewer said no: no letter is coming, so the ask goes
    LETTER_ERROR: False,      # the gate could not answer (not installed, timed out, unreadable): it holds nothing
    LETTER_MISSING: False,    # authored, and no gate answer on record: nobody is reviewing it
    LETTER_NONE: False,       # no letter: the ladder owes this request nothing now, or is not running on this host
}
# An ask whose approved WORDING a ruling has overtaken. It is listed by the table above like any other and then
# refused for its words (`run.ask_refusal`), in the ledger, the way an ask for a class with no approved copy is.
ASK_WORDING_SUPERSEDED = ("ASK_IDENTITY",)


def _ladder_slot(kind: str) -> bool:
    return kind in (KIND_ACK, KIND_EXTENSION, KIND_ACCESS, KIND_STATUS) or (kind or "").startswith("status-")


def ladder_letter(row: dict, sends: list[dict], msgs: list[dict]) -> str:
    """The letter the ladder has for THIS request: one key of `OLDER_ASK_STANDS_DOWN`.

      'sent'      a ladder message is out, or may be (a claimed or unknown send is "may have been sent")
      'approved'  one carries the reviewer's approval of its exact bytes and goes on the next send
      'pending'   one is authored and the gate has it queued for review
      'refused'   one is authored and the reviewer (or the gate's lint) refused it
      'error'     one is authored and the gate could not answer for it, or answered something unreadable
      'missing'   one is authored and no gate answer is on record for it
      ''          none. The ladder owes this request nothing now, or is not running on this host (no gate, or its
                  kill file): it authors nothing then.

    With more than one held message, the one the gate is still working on decides (pending), then a refusal, then an
    error: the request waits only while something of its own is actually in the queue."""
    if row.get("ack_sent_at") or row.get("status_sent_at"):
        return LETTER_SENT
    if any(_ladder_slot(s.get("kind") or "") and s.get("state") in ("sent", "sending", "unknown") for s in sends):
        return LETTER_SENT
    if any(m.get("state") in ("approved", "sent") for m in msgs):
        return LETTER_APPROVED
    got = {(m.get("gate_result") or "") for m in msgs if m.get("state") == "held"}
    if not got:
        return LETTER_NONE
    for verdict in (LETTER_PENDING, LETTER_REFUSED):
        if verdict in got:
            return verdict
    # "approved" on a message that is still held is not an approval this code can read as one: the gate's answer
    # and the row disagree, which is an error, not a letter that is going.
    return LETTER_ERROR if got - {""} else LETTER_MISSING


def older_ask(row: dict, kind: str, sends: list[dict], msgs: list[dict], first_authored_at: str,
              now: datetime) -> str:
    """Why the older ask must NOT be listed for this statutory request, or '' when it goes exactly as it did before
    the ladder existed.

    The rule (firstmate on QA finding 2 of #1908, twice): the ONLY suppression is where the gate genuinely holds a
    letter for this request. `OLDER_ASK_STANDS_DOWN` is that rule as a table over every value `ladder_letter` can
    return, and this function adds one bound to it and nothing else:

      * sent, approved: stands down. That letter states what we need, so the ask would be a second first message.
      * pending: stands down while the review is awaited, for no longer than `FALLBACK_HOURS` from when the request's
        first letter was authored. A verdict needs a review round this code does not run, and a round that never
        comes must not leave the request with nothing. A wait that cannot be measured is not a wait: the ask goes.
      * refused, error, missing, none: the ask goes now.

    `kind` does not enter the decision: the table is the same for every ask. Whether the ask's own WORDS may still be
    sent is a separate question with a separate answer (`run.ask_refusal`, `ASK_WORDING_SUPERSEDED`), and it is
    answered in the ledger, never by leaving the request off the list."""
    letter = ladder_letter(row, sends, msgs)
    if not OLDER_ASK_STANDS_DOWN[letter]:
        return ""
    if letter == LETTER_SENT:
        return "the ladder has written to this request, or may have"
    if letter == LETTER_APPROVED:
        return "the ladder holds a reviewed message for this request"
    first = first_authored_at or min((m.get("authored_at") or "") for m in msgs if m.get("state") == "held")
    try:
        waited = now - _parse(first)
    except ValueError:
        return ""
    if waited < timedelta(hours=FALLBACK_HOURS):
        return f"a ladder message has been in the review queue for under {FALLBACK_HOURS} h"
    return ""


def clock_unread(read_at: str, clock: dict, now: datetime, read_sha: str = "", deployed_sha: str = "") -> str:
    """The line for the page that deploys with the clock unit when requests are named and the firstmate check is
    not doing its job, or ''. Two ways it is not:

      * nobody has read the clock for `CLOCK_UNREAD_HOURS` (never registered, or stopped), or
      * somebody is reading it, with bytes that are not the check deployed beside this code (`read_sha` is what the
        reader sent with its last read, `deployed_sha` the sha256 of the deployed scripts/gdpr-dsar-clock-check.sh):
        the registration is older than the check, so what firstmate is told is the old check's idea of the clock.

    The check is registered in a firstmate home (scripts/gdpr-dsar-clock-register.sh), on a box no deploy reaches,
    so nothing here can install it; what this code can do is refuse to let either state be silent. `read_at` is the
    last `dsar clock --line --read-by firstmate`, '' when there has never been one. With no `deployed_sha` the
    second test is not made (a caller that cannot read the deployed check has nothing to compare)."""
    watched = len(clock.get("alarm") or []) + len(clock.get("no_first_message") or [])
    if not watched:
        return ""
    try:
        age = (now - _parse(read_at)).total_seconds() / 3600 if read_at else None
    except ValueError:
        age = None
    named = (f"{len(clock['alarm'])} statutory request(s) are inside {clock['alarm_days']} d of their date or past "
             f"it, {len(clock.get('no_first_message') or [])} have had no first message after "
             f"{NO_FIRST_MESSAGE_HOURS} h")
    fix = ("Run `scripts/gdpr-dsar-clock-register.sh` for the firstmate home (docs/support/gdpr-pipeline.md, "
           "\"The DSAR ladder\").")
    if age is None or age >= CLOCK_UNREAD_HOURS:
        since = f"in {age:.0f} h" if age is not None else "ever"
        return (f":rotating_light: *GDPR clock: the alarm to firstmate is NOT running.* {named}, and no firstmate "
                f"check has read the clock {since}. {fix}")
    if deployed_sha and read_sha != deployed_sha:
        return (f":rotating_light: *GDPR clock: the firstmate check reading the clock is not the one deployed.* "
                f"{named}. The reader sent {read_sha[:12] or 'no identity'}; the deployed check is "
                f"{deployed_sha[:12]}. {fix}")
    return ""


def state_of(row: dict, sends: list[dict]) -> str:
    if final_response_at(row, sends):
        return RESPONDED if in_flight(sends) else CLOSED
    if not contacted_at(row, sends):
        return RECEIVED
    return IN_PROGRESS if need_of(row) == NEED_NONE else IDENTITY_CHECK


# ------------------------------------------------------------------------------------------------------- copy
def load_copy(path: Path | None = None) -> dict:
    p = path or COPY_PATH
    try:
        raw = p.read_bytes()
        doc = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise CopyError(f"copy file {p} unreadable: {exc}") from exc
    if not isinstance(doc.get("blocks"), dict) or not isinstance(doc.get("variants"), dict):
        raise CopyError(f"copy file {p} has no blocks/variants")
    doc["_sha256"] = hashlib.sha256(raw).hexdigest()
    return doc


def render(copy_doc: dict, variant: str, facts: dict) -> str:
    """The exact body for `variant`. Only the date slots are filled; an unknown variant, a locked one, a missing
    block or an unfilled slot raises instead of producing a message."""
    v = copy_doc["variants"].get(variant)
    if not v:
        raise CopyError(f"no such variant: {variant}")
    if v.get("enabled") is not True:
        raise CopyError(f"variant {variant} is locked: {v.get('locked') or 'not enabled'}")
    parts = []
    for name in v["blocks"]:
        if name not in copy_doc["blocks"]:
            raise CopyError(f"variant {variant} names a missing block: {name}")
        parts.append(copy_doc["blocks"][name])
    body = "\n\n".join(parts)
    for slot in SLOTS:
        if "{" + slot + "}" in body:
            if not facts.get(slot):
                raise CopyError(f"variant {variant} needs {{{slot}}} and none was given")
            body = body.replace("{" + slot + "}", facts[slot])
    return body


def lint(body: str, kind: str, facts: dict, row: dict | None = None, late: bool = False) -> str:
    """'' when clean, else the first problem. Deterministic; runs before a body is queued for review."""
    if not body.strip():
        return "empty body"
    if "{" in body or "}" in body:
        return "an unfilled slot is left in the body"
    if len(body) > BODY_MAX:
        return f"body is {len(body)} characters (limit {BODY_MAX})"
    hit = BARRED_RE.search(body)
    if hit:
        return f"barred wording: '{hit.group(0)}'"
    if kind == KIND_ACK and (not facts.get("due") or facts["due"] not in body):
        return "an acknowledgement must state the deadline"
    if kind == KIND_EXTENSION and (not facts.get("due") or facts["due"] not in body):
        return "an extension notice must state the new date"
    if APOLOGY_RE.search(body) and not late:
        return "an apology outside an update to a request past its date"
    if late and not APOLOGY_RE.search(body):
        return "an update to a request past its date must say we are late and sorry"
    if kind == KIND_STATUS and (not facts.get("next") or facts["next"] not in body):
        return "a status update must say when the requester hears next"
    low = body.lower()
    for field in ("requester_name", "requester_email"):
        val = str((row or {}).get(field) or "").strip().lower()
        if len(val) >= 4 and val in low:
            return f"the body contains the requester's {field.split('_')[1]}"
    return ""


def variant_ids(copy_doc: dict) -> list[str]:
    return sorted(copy_doc["variants"])


# ----------------------------------------------------------------------------------------------------- ladder
def status_slots(sends: list[dict]) -> list[dict]:
    return [s for s in sends if s.get("kind") == KIND_STATUS or str(s.get("kind", "")).startswith("status-")]


def next_status_slot(sends: list[dict]) -> str:
    n = sum(1 for s in status_slots(sends) if s.get("state") == "sent") + 1
    return KIND_STATUS if n == 1 else f"status-{n}"


def owed(row: dict, sends: list[dict], now: datetime, open_from_requester: int = 1,
         answerable: bool = True) -> dict | None:
    """The ONE ladder message this request is owed right now, or None.

    Returns {"kind", "slot", "variant", "facts", "next_contact_at", "effects"} with no body: `render` makes the
    body, so the decision and the wording stay separately testable. `effects` are the register columns the message
    commits us to, written when (and only when) it is sent. `open_from_requester` is how many open statutory
    requests the same requester has, this one included. `answerable` is whether code can produce this request's
    answer today (False for an access request while no complete copy can be built): a message never states an
    answer date for an answer nothing here can produce, and the date is never moved for one it can.
    """
    if row.get("class") not in STATUTORY or row.get("status") != "open" or final_response_at(row, sends):
        return None
    if not (row.get("gates") or {}).get("v"):
        # Not through the identity chain yet (a row from before the chain existed, until its next decision): what it
        # needs is not known, so no message says so. The clock still names it.
        return None
    need = need_of(row)
    d = due(row)
    received = human_date(_parse(row["received_at"]))
    # A letter that MAY be out (`sending` / `unknown`) keeps the request quiet like one that did go: a status update
    # an hour after an ask nobody can confirm is the double contact the ledger exists to prevent.
    last = max([contacted_at(row, sends)] + [s.get("at") or "" for s in sends
                                             if s.get("state") in ("sending", "unknown")])
    quiet = bool(last) and now - _parse(last) < timedelta(days=QUIET_DAYS)

    # Art. 12(3) extension: "may be extended ... where necessary". Sent ONLY when a need for the extra time is
    # RECORDED against this request with the ruling that found it (`extension_need`, `extension_need_ruling`, written
    # by `dsar extend`): how many requests a person has and how near the date is are facts code can count, and neither
    # one shows that more time is necessary (QA review of #1908). ONLY when code cannot send the answer today: where
    # it can, the answer goes and no time is needed. ONLY where the ground named is itself a fact (the number of
    # requests, counted from the register). ONLY while the first month is still running (the rule requires the notice
    # within it, and an extension must never paper over a date already missed: lateness is said plainly by the late
    # update below), inside the alarm window, with nothing needed from the requester. "Complexity" is the rule's
    # other ground: no code can measure it, so nothing here selects it.
    left = d - now
    recorded = (row.get("extension_need") or "").strip() and (row.get("extension_need_ruling") or "").strip()
    if (need == NEED_NONE and recorded and not answerable and not row.get("extended_until")
            and open_from_requester >= EXTENSION_MIN_REQUESTS and timedelta(0) < left <= timedelta(days=ALARM_DAYS)):
        new = min(extension_limit(row["received_at"]), add_months(statutory_due(row["received_at"]), EXTENSION_MONTHS))
        return {"kind": KIND_EXTENSION, "slot": KIND_EXTENSION, "variant": "extension_number",
                "facts": {"received": received, "due": human_date(new)}, "next_contact_at": _iso(new),
                "effects": {"extended_until": _iso(new), "extension_reason": "number",
                            "extension_ruling": row["extension_need_ruling"].strip()}}

    # An acknowledgement, and an in-time status update, both tell the requester they will have our answer by the date.
    # With less than ACK_MIN_RUNWAY_DAYS left that is a promise nothing here can keep, so a request first reached that
    # late gets neither (see below). A new request is acknowledged within the hour, with the whole month ahead.
    if d - now >= timedelta(days=ACK_MIN_RUNWAY_DAYS):
        if not first_contact_made(row, sends):
            return {"kind": KIND_ACK, "slot": KIND_ACK, "variant": f"ack_{need}", "effects": {},
                    "facts": {"received": received, "due": human_date(d)}, "next_contact_at": _iso(d)}
        halfway = _parse(row["received_at"]) + (d - _parse(row["received_at"])) / 2
        if now >= halfway and not row.get("status_sent_at") and not quiet:
            return {"kind": KIND_STATUS, "slot": next_status_slot(sends), "variant": f"status_{need}", "effects": {},
                    "facts": {"received": received, "next": human_date(d)}, "next_contact_at": _iso(d)}
        return None

    # Too near the date, and not past it: nothing is owed until the date itself. An acknowledgement would state a
    # deadline we cannot promise, and the late update says "we are late", which is not true yet. The clock names the
    # request the whole time, and the late update is owed the moment the date passes.
    if now < d:
        return None
    # Past the date. No acknowledgement any more (it would state a deadline that has gone): a status update that
    # says we are late and commits to the next contact, repeated until the final response.
    promised = row.get("next_contact_at") or ""
    if promised and _parse(promised) > d:
        if now < _parse(promised) - timedelta(days=LATE_LEAD_DAYS):
            return None
    elif not promised and quiet:
        return None
    # Every late update says we are late and that we are sorry, with no reason given. Where we need nothing from the
    # requester it also states the date they get the ANSWER, and that date is recorded on the row so the clock can
    # name it when it is missed. Where the answer waits on them, on a read we could not make, or on an answer code
    # cannot produce yet, no answer date is stated (nothing here could keep it): the update gives the next-contact
    # date instead.
    variant = f"late_{need}"
    if need == NEED_NONE and answerable:
        nxt = now + timedelta(days=LATE_ANSWER_DAYS)
        effects = {"answer_promised_at": _iso(nxt)}
    else:
        nxt, effects = now + timedelta(days=LATE_INTERVAL_DAYS), {}
        if need == NEED_NONE:
            variant = LATE_NO_DATE_VARIANT
    return {"kind": KIND_STATUS, "slot": next_status_slot(sends), "variant": variant, "effects": effects,
            "facts": {"received": received, "next": human_date(nxt)}, "next_contact_at": _iso(nxt)}


def stale(msg: dict, want: dict, row: dict, now: datetime) -> bool:
    """Should a held (authored, not sent) message be replaced by a freshly authored one?

    A held body is kept as it is while it is still TRUE, so its hash stays the one under review. It is replaced when
    the message owed is a different one, when what it states has changed, or when a late update's promised date is
    too near to keep.

    "What it states" is the facts code filled in and, when the caller has rendered the body owed now (`want["text"]`),
    the bytes themselves. A held acknowledgement whose request was folded into an earlier one (receipt moves back),
    or whose date an extension moved, states a deadline that is no longer the deadline; approved later, the frozen
    body would send it (QA review of #1908). A late update's next date is `now` + an interval, so it differs on
    every run by design: it is left out of the comparison and judged by its runway alone."""
    if msg.get("variant") != want["variant"] or msg.get("slot") != want["slot"]:
        return True
    late = want["variant"].startswith("late_")
    held, owed_now = dict(msg.get("facts") or {}), dict(want.get("facts") or {})
    kept_next, new_next = held.get("next") or "", owed_now.get("next") or ""
    if late:
        held.pop("next", None)
        owed_now.pop("next", None)
    if held != owed_now:
        return True
    text = want.get("text") or ""
    if text:
        if late and kept_next and new_next:
            text = text.replace(new_next, kept_next)
        if text != (msg.get("body") or ""):
            return True
    if late:
        promised = msg.get("next_contact_at") or ""
        return not promised or _parse(promised) - now < timedelta(days=LATE_MIN_RUNWAY_DAYS)
    return False


# ------------------------------------------------------------------------------------------------------ alarm
def clock_rows(rows: list[dict], sends_of, now: datetime, alarm_days: int = ALARM_DAYS) -> dict:
    """Every statutory request with no final response, with the ones inside `alarm_days` of their date (or past
    it) named. `sends_of(row_id)` returns that request's ledger rows.

    A register row closed with no recorded response is not dropped: it is listed under `closed_without_response`,
    because a closed status with nothing sent is the state this module exists to make impossible.
    """
    alarm, open_rows, anomalies = [], [], []
    for r in rows:
        if r.get("class") not in STATUTORY:
            continue
        if r.get("status") == "duplicate":
            continue
        sends = sends_of(r["id"])
        if final_response_at(r, sends):
            continue
        if r.get("status") == "closed":
            anomalies.append(r["register_no"])
            continue
        d = due(r)
        days_left = (d - now).total_seconds() / 86400
        held = next((f"{s['kind']} {s['state']}: {(s.get('detail') or '')[:120]}" for s in sends
                     if s.get("state") in ("refused", "failed", "unknown", "sending")), "")
        item = {"register_no": r["register_no"], "class": r["class"], "state": state_of(r, sends),
                "received_at": r["received_at"], "due_at": _iso(d), "days_left": round(days_left, 2),
                "need": need_of(r), "last_message_at": contacted_at(r, sends), "held": held,
                "answer_promised_at": r.get("answer_promised_at") or "",
                # any message of ours counts (a status update is one), and so does a send that MAY be out
                "first_message": bool(contacted_at(r, sends)) or first_contact_made(r, sends)}
        open_rows.append(item)
        if days_left <= alarm_days:
            alarm.append(item)
    open_rows.sort(key=lambda x: (x["due_at"], x["register_no"]))
    alarm.sort(key=lambda x: (x["due_at"], x["register_no"]))
    past = [x for x in alarm if x["days_left"] < 0]
    return {
        "at": _iso(now), "alarm_days": alarm_days, "open": len(open_rows),
        "past_due": len(past), "due_within_window": len(alarm) - len(past),
        "oldest_open": open_rows[0] if open_rows else None,
        "alarm": alarm, "closed_without_response": sorted(anomalies),
        # An answer date WE stated in a late update, now gone with no answer out. Never silent: a date we chose and
        # missed is worse than the statutory one, because the requester was told it by us.
        "promises_missed": [x["register_no"] for x in open_rows
                            if x["answer_promised_at"] and _parse(x["answer_promised_at"]) < now],
        # Nobody has written to this request, and it is two days old. Whatever the reason (no reviewed letter yet,
        # no route, a class the older ask no longer serves), it is named: a request must never be quiet AND unseen.
        "no_first_message": [x["register_no"] for x in sorted(open_rows, key=lambda x: (x["received_at"],
                                                                                         x["register_no"]))
                             if not x["first_message"] and _unanswered_hours(x["received_at"], now)
                             >= NO_FIRST_MESSAGE_HOURS],
        "no_first_message_hours": NO_FIRST_MESSAGE_HOURS,
        # The same question at the target itself: the first message is due `FIRST_REPLY_HOURS` after arrival. This
        # list is the measure of that target (JSON only: the line a pager reads keeps the 48 h list above).
        "first_reply_overdue": [x["register_no"] for x in sorted(open_rows, key=lambda x: (x["received_at"],
                                                                                           x["register_no"]))
                                if not x["first_message"] and _unanswered_hours(x["received_at"], now)
                                >= FIRST_REPLY_HOURS],
        "first_reply_hours": FIRST_REPLY_HOURS,
    }


def _unanswered_hours(received_at: str, now: datetime) -> float:
    try:
        return (now - _parse(received_at)).total_seconds() / 3600
    except ValueError:
        return float("inf")          # a receipt time that cannot be read is not a reason to stay quiet


def clock_line(clock: dict) -> str:
    """One line for the firstmate page; '' when nothing is inside the window.

    EVERY request inside the window is named, however many there are. The line once named the first 12 and said
    "and N more": with 190 inside the window that left 178 requests the alarm did not name, and a request the alarm
    does not name is a request waiting for somebody to go and look (QA review of #1908)."""
    alarm = clock["alarm"]
    quiet = clock.get("no_first_message") or []
    if not alarm and not clock["closed_without_response"] and not quiet:
        return ""
    names = ", ".join(
        f"#{x['register_no']} ({'%d d past' % -int(x['days_left']) if x['days_left'] < 0 else 'due in %d d' % int(x['days_left'])})"
        for x in alarm)
    odd = (f"; closed with no recorded response: {', '.join('#%s' % n for n in clock['closed_without_response'])}"
           if clock["closed_without_response"] else "")
    missed = clock.get("promises_missed") or []
    broke = (f"; an answer date we stated has passed for: {', '.join('#%s' % n for n in missed)}"
             if missed else "")
    # Named once: a request already in the window is named above, so here it is only counted.
    named = {x["register_no"] for x in alarm}
    fresh = [n for n in quiet if n not in named]
    also = len(quiet) - len(fresh)
    unheard = ""
    if quiet:
        unheard = (f"; no first message after {clock.get('no_first_message_hours', NO_FIRST_MESSAGE_HOURS)} h: "
                   + (", ".join("#%s" % n for n in fresh) or "none besides")
                   + (f" (and {also} of those named above)" if also else ""))
    return (f"GDPR clock: {clock['past_due']} statutory request(s) past their date, {clock['due_within_window']} due "
            f"within {clock['alarm_days']} d, of {clock['open']} open. Oldest first: {names or 'none'}{odd}{broke}{unheard}")
