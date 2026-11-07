"""The machine-readable manifest a `bulk-credit-change` ticket must carry.

WHY A MANIFEST AND NOT PROSE
----------------------------
"Update credits on multiple tracks" is the ticket the customer files by pasting a
list. Read as prose it is unactionable: the track ids are ambiguous, the profile
is ambiguous, and the intended end state for each row is a guess. A drainer that
guesses on a batch of up to 25 credit writes is how the wrong credit lands on the
wrong profile and stays there.

So the intake emits a manifest, and the executor accepts nothing else:

    ---ACTION-REQUEST---
    {
      "action_type": "bulk-credit-change",
      "customer_profile_id": "<uuid>",
      "details": {
        "bulk_rows": [
          {"track_url": "https://credits.muso.ai/track/<uuid>",
           "profile_id": "<uuid>", "role": "Mixing", "intent": "add",
           "remove": false},
          ...
        ]
      }
    }
    ---END-ACTION-REQUEST---

(`track_id` may be given instead of `track_url`.) The natural home is the support
skill's `details` block, which is exactly where
`workspaces/support/skills/action-request/SKILL.md` puts it.

WHAT THIS MODULE DOES AND DOES NOT DECIDE
-----------------------------------------
It parses and shape-checks ONLY. It never talks to ClickUp, the admin API or the
network, so every refusal reason below is reproducible in a unit test. Row names
a track that does not exist? That is the admin API's answer to give
(`bulk_credit_change.py`), not this module's.

REFUSAL REASONS — REPORT BUCKETS, NOT OUTCOME TAGS
--------------------------------------------------
`unparseable`, `too-many-rows`, `row-invalid` and `removal-refused` are buckets
this drainer COUNTS. Only `removal-refused` also writes a `customer-outcome:blocked`
tag (a removal is a real request we are declining); the other three write no tag
at all, so the ticket stays `waiting-on-us` for the reconciler and surfaces in the
SLA digest. A prose-only ticket is the intake's problem and the count is what
tells the captain which side is broken.

`remove: true` and `from_role` are BOTH refused as removals. A role *change* is a
removal plus an add: adding Mastered while Mixing stays on the track leaves the
wrong credit in place, which is worse than not acting. Credit removal is core
#10310 territory — a named human runs it from their own login
(`skills-all/muso-ops-tracks/SKILL.md`, "Removal Requests"). This drainer never
implements it, so a ticket that needs a removal is refused loudly instead of
half-applied.

WHY EVERY ROW MUST SAY `intent: "add"`
--------------------------------------
A row that names only a role cannot distinguish "also credit me as Mastering"
from "change my Mixing to Mastering". Both arrive as `role: "Mastering"`, and the
second one is a removal plus an add: this drainer would add Mastering, read it
back, and report `complete` while Mixing still displays — the customer's actual
request silently half-done, and the ticket closed. So the intent is REQUIRED and
only `add` is executable. A row that says `replace`/`change`/`swap` is refused as
a removal (`removal-refused`, which tags `blocked` and routes it to the human
path); a row that says nothing is `row-invalid` and tags nothing, because a
missing intent is an intake defect, not a customer request we are declining.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

ACTION_START = "---ACTION-REQUEST---"
ACTION_END = "---END-ACTION-REQUEST---"

#: Hard cap on one ticket's batch. One ticket = one bounded batch; a customer who
#: means 200 rows needs 8 tickets, not one 200-row write run.
MAX_ROWS = 25

#: Longest role name we will carry. Real catalog roles are short ("Mixing",
#: "Mastering", "Immersive Mixing"); anything longer is a pasted sentence.
MAX_ROLE_LEN = 80

# Row keys we understand. An unexpected key is a shape error, not something to
# silently ignore: `{"remove" : true}` misspelled as `{"removal": true}` must not
# read as "no removal requested".
ROW_KEYS = frozenset({"track_id", "track_url", "profile_id", "role", "intent", "remove"})

#: The only intent this drainer can execute. It ADDS a role; it never removes one.
INTENT_ADD = "add"

#: Intents that mean "the old role must go". Refused as removals, not as typos:
#: the request is real, it just belongs to a named human (core #10310).
INTENTS_REFUSED = frozenset({"replace", "change", "swap", "remove", "removal"})

# https://credits.muso.ai/track/<id>, https://muso.ai/track/<id>, trailing slash,
# optional query/fragment. Deliberately anchored: a URL that is not a muso track
# URL must not contribute an id by accident.
TRACK_URL_RE = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)*muso\.ai/(?:[a-z]{2}(?:-[a-z]{2})?/)?track/([^/?#]+)/?(?:[?#].*)?$",
    re.IGNORECASE,
)

REASON_UNPARSEABLE = "unparseable"
REASON_TOO_MANY_ROWS = "too-many-rows"
REASON_ROW_INVALID = "row-invalid"
REASON_REMOVAL_REFUSED = "removal-refused"
REASON_MISSING_PROFILE = "missing-profile-anchor"

#: Reasons that also write `customer-outcome:blocked`. The rest write nothing.
REASONS_THAT_TAG_BLOCKED = frozenset({REASON_REMOVAL_REFUSED})


class ManifestError(ValueError):
    """A ticket whose manifest we refuse. `reason` is one of the REASON_* codes."""

    def __init__(self, reason: str, detail: str):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True)
class Row:
    """One requested (track, profile, role) end state."""

    track_id: str
    profile_id: str
    role: str

    def as_dict(self) -> dict[str, str]:
        """The row as it appears in the ledger."""
        return {"track_id": self.track_id, "profile_id": self.profile_id, "role": self.role}


@dataclass(frozen=True)
class Manifest:
    """A validated batch. `customer_email` is carried for the ledger/evidence
    only — this drainer never messages the customer."""

    rows: list[Row]
    customer_profile_id: str
    customer_email: str | None = None


def parse_action_request(description: str | None) -> dict | None:
    """The `---ACTION-REQUEST---` JSON block of a ticket description, or None.

    Non-greedy on purpose: the description also carries markdown, and a greedy
    match would swallow everything after the block.
    """
    if not isinstance(description, str) or not description:
        return None
    m = re.search(
        re.escape(ACTION_START) + r"\s*(\{.*?\})\s*" + re.escape(ACTION_END),
        description,
        re.S,
    )
    if not m:
        return None
    try:
        payload = json.loads(m.group(1))
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def track_id_from_url(value: object) -> str | None:
    """The track id inside a muso track URL, or None when it is not one."""
    if not isinstance(value, str):
        return None
    m = TRACK_URL_RE.match(value.strip())
    return m.group(1) if m else None


def _row_ids(raw: dict, index: int) -> tuple[str, str, str]:
    unknown = set(raw) - ROW_KEYS
    if unknown:
        raise ManifestError(
            REASON_ROW_INVALID,
            f"row {index}: unknown key(s) {sorted(unknown)} (allowed: {sorted(ROW_KEYS)})",
        )
    intent = raw.get("intent")
    if intent is None:
        raise ManifestError(
            REASON_ROW_INVALID,
            f'row {index}: intent is missing — say intent: "add" (this drainer only '
            "adds a role; a replacement or removal is a named human's job)",
        )
    if not isinstance(intent, str):
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: intent must be a string")
    intent = intent.strip().lower()
    if intent in INTENTS_REFUSED:
        raise ManifestError(
            REASON_REMOVAL_REFUSED,
            f"row {index}: intent {intent!r} — a role change is a removal plus an add, "
            "and credit removals are core #10310 territory, a named human runs them "
            "from their own login",
        )
    if intent != INTENT_ADD:
        raise ManifestError(
            REASON_ROW_INVALID,
            f'row {index}: intent {intent!r} is not understood (only "add")',
        )
    if raw.get("remove") is True:
        raise ManifestError(
            REASON_REMOVAL_REFUSED,
            f"row {index}: remove=true — credit removals are core #10310 territory, "
            "a named human runs them from their own login",
        )
    if "remove" in raw and raw["remove"] not in (False, None):
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: remove must be false or absent")
    if {"track_id", "track_url"} <= set(raw):
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: give track_id or track_url, not both")

    track_id = raw.get("track_id")
    if track_id is not None:
        if not isinstance(track_id, str) or not track_id.strip():
            raise ManifestError(REASON_ROW_INVALID, f"row {index}: track_id is empty")
        track_id = track_id.strip()
    else:
        track_id = track_id_from_url(raw.get("track_url"))
        if track_id is None:
            raise ManifestError(
                REASON_ROW_INVALID,
                f"row {index}: track_url is not a muso track URL "
                f"(got {raw.get('track_url')!r})",
            )
    if not track_id or "/" in track_id:
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: malformed track id {track_id!r}")

    profile_id = raw.get("profile_id")
    if not isinstance(profile_id, str) or not profile_id.strip():
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: profile_id is missing")
    profile_id = profile_id.strip()
    if "/" in profile_id:
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: malformed profile id {profile_id!r}")

    role = raw.get("role")
    if not isinstance(role, str) or not role.strip():
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: role is missing")
    role = " ".join(role.split())
    if len(role) > MAX_ROLE_LEN:
        raise ManifestError(REASON_ROW_INVALID, f"row {index}: role is longer than {MAX_ROLE_LEN} chars")

    return track_id, profile_id, role


def _key_hint(details: dict) -> str:
    """Name the keys the intake DID emit, so a refusal tells it what to fix.

    Diagnosis, never coercion: a `tracks`/`requested_role` pair is not turned
    into rows. Guessing which track gets which role is exactly how the wrong
    credit lands on the wrong profile. Keys come from intake-controlled text, so
    they are flattened and bounded before they reach a log line.
    """
    keys = [re.sub(r"[^\w.:-]+", "_", str(k))[:40] for k in sorted(details)]
    shown = ", ".join(keys[:8]) + (f" (+{len(keys) - 8} more)" if len(keys) > 8 else "")
    return (
        f"details carries {{{shown}}} but not `bulk_rows` — the intake must emit "
        "the row list, not loose per-ticket fields"
    )


def parse_manifest(description: str | None) -> Manifest:
    """Parse and shape-check a ticket description. Raises ManifestError."""
    payload = parse_action_request(description)
    if payload is None:
        raise ManifestError(
            REASON_UNPARSEABLE,
            f"no readable {ACTION_START} JSON block — the intake must emit the "
            "structured block, not prose",
        )
    # `from_role` is the other way a ticket can ask for a removal in disguise.
    details = payload.get("details")
    if not isinstance(details, dict):
        raise ManifestError(REASON_UNPARSEABLE, "no details block")
    raw_rows = details.get("bulk_rows")
    if not isinstance(raw_rows, list) or not raw_rows:
        raise ManifestError(
            REASON_UNPARSEABLE,
            "details.bulk_rows is missing or empty — a ticket without the row list "
            "cannot be executed without guessing. " + _key_hint(details),
        )
    if len(raw_rows) > MAX_ROWS:
        raise ManifestError(
            REASON_TOO_MANY_ROWS,
            f"{len(raw_rows)} rows, cap is {MAX_ROWS} per ticket — file more tickets",
        )

    rows: list[Row] = []
    seen: set[tuple[str, str, str]] = set()
    for index, raw in enumerate(raw_rows):
        if not isinstance(raw, dict):
            raise ManifestError(REASON_ROW_INVALID, f"row {index}: not an object")
        if "from_role" in raw:
            raise ManifestError(
                REASON_REMOVAL_REFUSED,
                f"row {index}: from_role means the old role must go, which is a removal",
            )
        track_id, profile_id, role_key = _row_ids(raw, index)
        key = (track_id.lower(), profile_id.lower(), role_key.lower())
        if key in seen:
            raise ManifestError(
                REASON_ROW_INVALID,
                f"row {index}: duplicate of an earlier row (track {track_id}, role {role_key})",
            )
        seen.add(key)
        rows.append(Row(track_id=track_id, profile_id=profile_id, role=role_key))

    # The ticket's OWN profile is the identity anchor and it is REQUIRED. A batch
    # may only edit the account the ticket names, so an anchor-less ticket
    # (filed before create-ticket's PROFILE_ANCHOR_REQUIRED gate covered this
    # action type) is refused and counted rather than trusted: without it a row
    # naming any other profile would have nothing to be checked against.
    customer_profile_id = payload.get("customer_profile_id")
    if not isinstance(customer_profile_id, str) or not customer_profile_id.strip():
        raise ManifestError(
            REASON_MISSING_PROFILE,
            "customer_profile_id is missing — a batch may only edit the profile the "
            "ticket names, and this drainer will not edit an account it cannot name",
        )
    customer_profile_id = customer_profile_id.strip()

    customer_email = payload.get("customer_email")
    if not isinstance(customer_email, str) or not customer_email.strip():
        customer_email = None
    else:
        customer_email = customer_email.strip()

    return Manifest(
        rows=rows,
        customer_profile_id=customer_profile_id,
        customer_email=customer_email,
    )


def same_role(a: str, b: str) -> bool:
    """Role comparison used everywhere: catalog roles are free text, so compare
    whitespace-collapsed and case-insensitively rather than guessing which side
    normalises."""
    return " ".join(str(a).split()).casefold() == " ".join(str(b).split()).casefold()
