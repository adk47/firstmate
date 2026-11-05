"""The ask classifier: one regex table, ten classes, no model.

This is the table the router uses on every inbound Slack message on the
`operations` account, and the same table the Jan-asks census was taken with.
It is deliberately plain: ordered regexes, first match wins, and the class is
recorded on the ask row along with every other class the text also matched
(``candidates``) so a later reviewer can see what almost fired.

Why not a model: the class decides which coded answerer runs and which write
tier the ask may reach. A model in that seat is an injection surface, and the
census's own failure was verdict/attribution drift - not classification. The
fixture in ``tests/fixtures/ops-intake-census-asks.json`` pins this table to the
269 classified census rows (firstmate lane jan-asks-intake-fable-j1); the test
requires >= 95% agreement and lists the residual misses by name, so a regression
cannot hide inside the allowance.

Identity is NEVER derived here. ``*Jan Delmo* [12:09 AM] hide profile X`` is
text: :func:`classify` classifies it like any other message (gdpr-hide), and the
only thing the pasted-quote detector does is let the router say so out loud
(``impersonation_quote``) when a non-staff id sends one. See
``scripts/ops_intake/router.py``.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# The ten classes. `other` is the ONLY one an agent turn still sees
# (policies/ops-intake-actions.json .classes.other.agent_handles).
CLASSES: tuple[str, ...] = (
    "proof-review",
    "summarize-resolve",
    "gdpr-hide",
    "clickup-categorize",
    "status-report",
    "fraud-scan",
    "billing",
    "profile-edit",
    "relay",
    "other",
)

# The census used two labels the router folds into its ten. Recorded here (not
# in the fixture alone) so the mapping is visible at the place that classifies.
CENSUS_ALIASES: dict[str, str] = {
    "relay-to-firstmate": "relay",
    "process-question": "other",
}

# Ordering is the whole design: the first matching rule wins, so a more specific
# intent must sit above a more general one. The comments name the census rows
# that force each position - move a rule and read those rows first.
RULES: tuple[tuple[str, str, str], ...] = (
    # "change profile name to Franki Love", "create profile and source ..."
    ("profile-edit", "rename_profile",
     r"\bchange profile name\b|\bcreate profile\b|\brename\b|\bprofile name to\b"),

    # "read through clickup to do list", "move it to waiting", "put back to to-do
    # status if ... GDPR" - the ClickUp rule sits ABOVE gdpr-hide because those
    # later rows contain both words and the instruction is a ClickUp move.
    ("clickup-categorize", "clickup",
     r"\bclickup\b|\bto-?do\b|\bwaiting\b|\btickets?\b|"
     r"\bmove (?:it|the cases|the tickets) to\b|\bstatus (?:on|to)\b"),

    # "hide profile: profile 7127c801…", "hide the following from public"
    ("gdpr-hide", "hide_entities",
     r"\bhide\b[^.\n]{0,60}\b(?:profile|track|public|artist|songs?|catalog)\b|"
     r"\bhide the following\b|\btakedown\b"),

    # "can you help trace this transaction", "check in prodigi ...",
    # "send me ... the workspace id, email address that the transaction was used".
    # Refund is NOT a billing cue: the census files "yes refund it" and
    # "cancel and prorate the refund" under summarize-resolve, because the ask was
    # a resolution on a conversation, not a billing trace.
    ("billing", "billing_trace",
     r"\btransactions?\b|\bprodigi\b|\binvoice\b|\bstripe\b|\bworkspace id\b|\bcard was used\b"),

    # "fraud scan profile 576e3c2d…", "this is fraudster. reject all credit claims",
    # "tell firstmate that this profile is fraud profile 576e3c2d…"
    ("fraud-scan", "fraud",
     r"\bfraud\w*\b|\breject all credit claims\b|\bremove all the credits\b|\bimpostor\b"),

    # Proof REVIEW, not "ask the user for proof" (which is summarize-resolve and
    # is caught by the update-user rule below only when no review verb rides
    # along). Either a proof word with a review verb within one clause, or a proof
    # word on a message addressed to firstmate ("tell firstmate that the user
    # provided a proof"), or a bare "verdict"/"documents sufficient".
    ("proof-review", "proof_review",
     r"\bproofs?\b[^.\n]{0,120}\b(?:review|verdict|sufficient|enough|approv\w*|fix|resolv\w*|"
     r"credit verification|verif\w*|document\w*)\b|"
     r"\b(?:review|verdict|decide|approved?|sufficient|enough|credit verification)\b[^.\n]{0,120}\bproofs?\b|"
     r"\bfirstmate\b[^.\n]{0,120}\bproofs?\b|\bproofs?\b[^.\n]{0,120}\bfirstmate\b|"
     r"\bdocuments?\b[^.\n]{0,40}\b(?:sufficient|enough)\b|\bverdict\b"),

    # "update the user", "ask the user for proofs", "ask user for the proof",
    # "inform the user" - a resolution step performed on a conversation.
    ("summarize-resolve", "update_user",
     r"\b(?:update|ask|tell|inform|message|advise)\s+(?:the\s+)?user\b|\bask user\b|"
     r"\buser was updated\b|\bask for\b|\bask (?:the )?user (?:again )?for\b"),

    # "give me the breakdown", "how many", "number of cases per category",
    # "prepare detailed report for aaron", "check the movements from 48hrs"
    ("status-report", "status_report",
     r"\bbreakdown\b|\bhow many\b|\bnumber of\b|\bper category\b|\bdetailed report\b|"
     r"\breport (?:for|to) aaron\b|\bmovements?\b|\bcounts?\b|\bprepared report\b"),

    # Anything still addressed to firstmate: "ask firstmate for update",
    # "is there update from firstmate?", "tell firstmate ...".
    ("relay", "firstmate_relay", r"\bfirstmate\b"),

    # "give me summary and resolution intercom 215476444480749",
    # "do resolution then update the user", "try offering 50% discount"
    ("summarize-resolve", "summarize_resolve",
     r"\bsummar\w*\b|\bresolution\b|\bresoltuion\b|\bresolved?\b|\bintercom\b|\brefund\b|"
     r"\bcancel\b|\boffer\w*\b|\bdiscount\b|\bprorate\b|\bresolv\w*\b|\bupdate here\b"),
)

_COMPILED: tuple[tuple[str, str, re.Pattern[str]], ...] = tuple(
    (cls, name, re.compile(pattern, re.IGNORECASE)) for cls, name, pattern in RULES
)

# A pasted Slack quote header, e.g. "*Jan Delmo* [12:09 AM]". It is DATA: it may
# raise a refusal when a non-staff id sends one, and it never becomes identity.
QUOTED_SPEAKER = re.compile(r"\*[A-Z][^*\n]{1,60}\*\s*\[\d{1,2}:\d{2}\s*(?:AM|PM)?\]", re.IGNORECASE)


@dataclass(frozen=True)
class Classification:
    """What the table said, and nothing it did not say."""

    cls: str
    rule: str
    candidates: tuple[str, ...] = ()
    text_sha256: str = ""
    impersonation_quote: str | None = None
    matched: tuple[tuple[str, str], ...] = field(default=())

    @property
    def is_other(self) -> bool:
        return self.cls == "other"


def classify(text: str, *, text_sha256: str = "") -> Classification:
    """Classify ONE message body. First matching rule wins; all matches recorded."""
    body = text or ""
    hits = [(cls, name) for cls, name, rx in _COMPILED if rx.search(body)]
    quote = QUOTED_SPEAKER.search(body)
    if not hits:
        return Classification(
            cls="other",
            rule="no_match",
            candidates=(),
            text_sha256=text_sha256,
            impersonation_quote=quote.group(0) if quote else None,
            matched=(),
        )
    return Classification(
        cls=hits[0][0],
        rule=hits[0][1],
        candidates=tuple(dict.fromkeys(c for c, _ in hits)),
        text_sha256=text_sha256,
        impersonation_quote=quote.group(0) if quote else None,
        matched=tuple(hits),
    )


def census_class(name: str) -> str:
    """Map a census label onto the router's ten classes."""
    return CENSUS_ALIASES.get(name, name)
