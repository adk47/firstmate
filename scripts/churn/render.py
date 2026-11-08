"""Render ``wb_fix_1``: the one message a churned user gets, from the fix we can prove.

The copy is fixed text from ``policies/winback-fix.json`` (Fable-reviewed skeleton, report
3.2). There is no model call and no free text anywhere in it: six FIX_LINE variants, chosen by
cause class, with the numbers taken from the read-back. The one exception is ``other``, whose
FIX_LINE is a sentence from the human reply that was already sent in Intercom - a real answer
to that person, quoted, not a new one invented for a campaign.

Three rules the renderer enforces rather than documents:

1. **No unfillable placeholder is ever left in a body.** If the read-back cannot supply the
   numbers a variant needs, the user is INELIGIBLE (`Rendered.ineligible_reason`), because a
   message that says "{n} of your pending credits are now approved" to someone whose credits
   were not approved is worse than silence (R2). A refusal whose cause is the POLICY or the copy
   rather than this user's data is a ``PolicyGap`` instead: it sets ``ineligible_fixable`` so the
   caller records the reason and leaves the ticket sendable, because the repair is an edit.
2. **Offers are the approved set and nothing else** (R3): monthly -> WB_M2_MONTH1, annual ->
   WB_M2_ANNUAL40 (the live slugs in muso-messaging contracts/email/coupons.json), payment_failed
   -> the restart link and NO coupon, Regional Discount -> the country coupon they already had
   plus the regional sentence (flagged for Fable GO). Every offer_line carries the redeem URL it
   tells the reader to use: "with this link:" and no link is a body the guards refuse.
3. **Only dates we hold.** The plan end date comes from the store's own cancel timestamp and
   the offer expiry from the policy file; nothing else is formatted as a date at all.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Mapping

from . import coupons

CAMPAIGN = "wb_fix_1"
_MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December")
_PLACEHOLDER = re.compile(r"\{([a-z_]+)\}")
_FIRST_NAME_OK = re.compile(r"^[^\W\d_](?:[^\W\d_]|['.-]){0,39}$", re.UNICODE)
_MONEY = re.compile(r"^\d+(?:\.\d{2})?$")


class RenderRefused(Exception):
    """The body cannot be produced honestly for this user. Never softened into a guess."""


class PolicyGap(RenderRefused):
    """A refusal no user can fix: a hole in the policy or the copy, which a later edit closes.

    The distinction is load-bearing. A per-user evidence gap is a dead end for that person, so
    their ticket may be closed as ineligible. A policy gap blocks everyone it touches and is
    repaired by editing ``policies/winback-fix.json``, so their tickets stay sendable.
    """


@dataclass
class Rendered:
    user_id: str
    subject: str
    body: str
    variant: str                    # the cause class the FIX_LINE came from
    fix_line: str
    offer_line: str
    coupon: str | None
    plan_noun: str
    pro_ended_date: str
    ineligible_reason: str | None = None
    ineligible_fixable: bool = False
    offer_url: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def eligible(self) -> bool:
        return self.ineligible_reason is None

    def as_dict(self) -> dict[str, Any]:
        return {
            "user_id": self.user_id,
            "subject": self.subject,
            "body": self.body,
            "variant": self.variant,
            "fix_line": self.fix_line,
            "offer_line": self.offer_line,
            "coupon": self.coupon,
            "offer_url": self.offer_url,
            "plan_noun": self.plan_noun,
            "pro_ended_date": self.pro_ended_date,
            "eligible": self.eligible,
            "ineligible_reason": self.ineligible_reason,
            "ineligible_fixable": self.ineligible_fixable,
            "notes": list(self.notes),
        }


def date_words(epoch: float) -> str:
    """A long English date (month name, day, year) from an epoch, UTC, no locale dependence."""
    import time as _t

    tm = _t.gmtime(float(epoch))
    return f"{_MONTHS[tm.tm_mon - 1]} {tm.tm_mday}, {tm.tm_year}"


def first_name(raw: Any) -> str:
    """The gate's own rule (scripts/paid-status/email_route.py): a real given name or 'there'."""
    word = str(raw or "").strip().split(" ")[0]
    return word if _FIRST_NAME_OK.match(word) else "there"


def plan_noun(plan: str, policy: Mapping[str, Any]) -> str:
    mapping = policy.get("plan_nouns") or {}
    for prefix, noun in mapping.items():
        if prefix.startswith("_") or prefix == "default":
            continue
        if str(plan or "").startswith(prefix):
            return str(noun)
    return str(mapping.get("default") or "Muso Pro")


def fix_line_for(cause_class: str, evidence: Mapping[str, Any], policy: Mapping[str, Any],
                 *, human_reply: str | None = None) -> tuple[str, list[str]]:
    """(FIX_LINE, notes) for one cause class, or raise RenderRefused.

    ``evidence`` is the read-back's own record. Every branch either has a number the read-back
    measured or refuses - there is no "probably" branch.
    """
    lines = policy.get("fix_lines") or {}
    template = str(lines.get(cause_class) or lines.get("other") or "").strip()
    if not template:
        raise PolicyGap(f"no FIX_LINE template for cause class {cause_class!r}")
    notes: list[str] = []
    values: dict[str, Any] = {}

    if cause_class == "credits_not_approved":
        approved = int(evidence.get("credits_approved") or 0)
        declined = int(evidence.get("credits_declined") or 0)
        if approved + declined <= 0:
            raise RenderRefused("read-back found no credit decision for this user")
        if approved <= 0:
            # "0 of your pending credits are now approved" is not a fix, it is a second insult.
            raise RenderRefused("read-back found no approved credit (only declined rows)")
        values["n"] = approved
        values["declined_clause"] = (
            f", and {declined} {'was' if declined == 1 else 'were'} declined with the reason in your account"
            if declined else ""
        )
    elif cause_class == "proof_sent_no_update":
        approved = int(evidence.get("credits_approved") or 0)
        if approved < 1:
            raise RenderRefused("the documents were reviewed but no credit is approved (report 3.2)")
        values["n"] = approved
    elif cause_class == "merge_claim_stuck":
        kind = str(evidence.get("merge_claim_result") or "").strip().lower()
        results = policy.get("merge_claim_results") or {}
        if kind not in ("merge", "claim") or not str(results.get(kind) or "").strip():
            raise RenderRefused("the read-back did not say whether the merge or the claim completed")
        template = str(results[kind])
        notes.append(f"{kind} outcome recorded")
    elif cause_class == "analytics_stale_wrong":
        platform = str(evidence.get("platform") or "").strip()
        if not platform:
            raise RenderRefused("the read-back did not name the platform whose numbers were refreshed")
        values["platform"] = platform
    elif cause_class == "billing_confusion":
        amount = str(evidence.get("refund_amount") or "").strip().lstrip("$")
        if not _MONEY.match(amount):
            raise RenderRefused("no refund object amount in the read-back")
        values["amount"] = f"${amount}"
    elif cause_class == "other":
        reply = str(evidence.get("human_reply_sentence") or evidence.get("human_reply")
                    or human_reply or "").strip()
        if not reply:
            raise RenderRefused("no human reply to quote on this thread")
        min_words = int(((policy.get("guards") or {}).get("human_reply_sentence_min_words")) or 8)
        sentence = quote_fix_sentence(reply, min_words=min_words).rstrip(". ").strip()
        if not sentence:
            raise PolicyGap("no sentence in the human reply names the fix to quote")
        # The sentence rides mid-body, where the template supplies the full stop. Keeping the
        # reply's own period would render "so.”." - a typo in a message about our care.
        values["human_reply_sentence"] = f"“{sentence}”"
    else:  # pragma: no cover - normalize_class guarantees the six
        raise PolicyGap(f"unknown cause class {cause_class!r}")

    try:
        return template.format(**values), notes
    except KeyError as exc:  # a template we control, so this is a policy bug, not user data
        raise PolicyGap(f"FIX_LINE template for {cause_class!r} needs {exc}") from exc


#: A reply sentence that opens with one of these is a greeting, not the answer (see
#: :func:`quote_fix_sentence`). Support replies normally start this way.
_PLEASANTRY_OPENERS = re.compile(
    r"^(?:hi|hello|hey|dear|good (?:morning|afternoon|evening))\b"
    r"|^thanks?\b|^thank you\b|^sorry\b|^apologies\b|^my apologies\b|^quick note\b",
    re.I,
)
#: A sentence that states the OUTCOME the user waited for. The quoted line has to carry one of
#: these: R2 says the message names what was fixed, so a sentence without an outcome is not it.
_OUTCOME_WORDS = re.compile(
    r"\b(?:approved?|approval|merged?|processed|refunded|reversed|refreshed|updated|corrected|fixed|"
    r"completed?|done|added|removed|restored|live|now (?:show|shows|showing|on|visible)|no longer|is on|are on)\b",
    re.I,
)
_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")


def sentences(text: str) -> list[str]:
    """The reply split into trimmed sentences (no abbreviation parser: replies are plain prose)."""
    cleaned = " ".join(str(text or "").split())
    if not cleaned:
        return []
    return [s.strip() for s in _SENTENCE_SPLIT.split(cleaned) if s.strip()]


def quote_fix_sentence(text: str, *, min_words: int = 8, max_words: int = 60) -> str:
    """The sentence of a human reply that STATES THE FIX - never the greeting, never a pleasantry.

    Support replies open with "Hi Nadia, thanks for waiting." A quote of that sentence tells the
    customer nothing about what we fixed, which is the one thing R2 requires the message to say.
    So: skip pleasantries and sentences with no outcome in them, and return ``""`` when no
    sentence states one. The floor is the policy's ``guards.human_reply_sentence_min_words`` -
    the WHOLE reply has its own, stricter floor in ``readback.intercom_verdict``, because a real
    answer can be long while the one sentence we quote is short. ``""`` is a fixable policy gap
    (the answer may be re-worded), never a per-user dead end.
    """
    for sentence in sentences(text):
        body = sentence.strip().rstrip(".!? ").strip()
        words = body.split()
        if len(words) < min_words or len(words) > max_words:
            continue
        if _PLEASANTRY_OPENERS.match(body) and not _OUTCOME_WORDS.search(body):
            continue
        if not _OUTCOME_WORDS.search(body):
            continue
        return body
    return ""


def offer_url_for(*, annual: bool, plan: str, reason: str, policy: Mapping[str, Any]) -> str:
    """The redeem link for this user's offer, built from the policy's live coupon slug.

    The send-gateway applies a coupon ONLY through ``offer=<slug>`` (an offer-only AMP row in
    core-backend), so the URL is the offer: the slug here is the same one coupons.json carries.
    """
    offers = policy.get("offers") or {}
    if str(reason or "").lower() == "payment_failed":
        row = offers.get("payment_failed") or {}
        slug = row.get("slug")
        period = str(row.get("period") or ("annual" if "annual" in plan.lower() else "monthly"))
    else:
        row = offers.get("annual" if annual else "monthly") or {}
        slug = row.get("slug")
        period = str(row.get("period") or ("annual" if annual else "monthly"))
    template = str(offers.get("offer_url") or "").strip()
    if not template:
        raise PolicyGap("policies/winback-fix.json offers.offer_url is missing")
    if slug:
        return template.format(period=period, slug=slug)
    if str(reason or "").lower() == "payment_failed":
        # No coupon to apply: the same login/pricing round trip, with no offer slug.
        stripped = template.replace("%26offer%3D{slug}", "")
        if "{slug}" in stripped:
            raise PolicyGap("policies/winback-fix.json offers.offer_url must spell the offer "
                            "parameter as %26offer%3D{slug}, so a payment_failed link can drop it")
        return stripped.format(period=period, slug="")
    raise PolicyGap(f"no coupon slug configured for {'annual' if annual else 'monthly'}: the offer would be a dead link")


def offer_for(reason: str, *, annual: bool, regional: bool, policy: Mapping[str, Any],
              plan: str = "", regional_coupon: str | None = None) -> tuple[str, str | None, str]:
    """(offer_line, coupon, offer_url). R3: the approved set only; a card failure gets no coupon."""
    offers = policy.get("offers") or {}
    key = "payment_failed" if str(reason or "").lower() == "payment_failed" else (
        "annual" if annual else "monthly")
    row = offers.get(key) or {}
    line = str(row.get("offer_line") or "").strip()
    if not line:
        raise PolicyGap(f"no offer_line configured for {key}")
    url = offer_url_for(annual=annual, plan=plan, reason=reason, policy=policy)
    line = line.replace("{offer_url}", url)
    if "{redeem_by}" in line:
        redeem_by = str(row.get("redeem_by") or "").strip()
        if not redeem_by:
            raise PolicyGap("the monthly offer names a redeem-by date the policy does not hold")
        line = line.replace("{redeem_by}", redeem_by)
    if "this link" in line.lower() and "muso.ai/" not in line:
        raise PolicyGap("the offer sentence promises a link the policy did not supply")
    coupon = row.get("coupon")
    if regional:
        suffix_row = offers.get("regional_suffix") or {}
        suffix = str(suffix_row.get("text") or "").strip()
        if suffix:
            # The suffix asserts a PRICE, so the policy's own flag has to gate it: the template GO
            # covers the six FIX_LINE variants, not a seventh sentence.
            if suffix_row.get("requires_fable_go") and not str(suffix_row.get("fable_go_ref") or "").strip():
                raise PolicyGap("the regional sentence is not approved yet: policies/winback-fix.json "
                                "offers.regional_suffix.fable_go_ref is unset")
            if regional_coupon == coupons.HELD:
                line = f"{line}{suffix if suffix.startswith(' ') else ' ' + suffix}"
    return line, (str(coupon) if coupon else None), url


def render(*, ticket: Any, policy: Mapping[str, Any], recipient: Mapping[str, Any] | None = None,
           human_reply: str | None = None, regional_coupon: str | None = None) -> Rendered:
    """Render the campaign body for one Seen ticket.

    ``ticket`` is a ``churn.tickets.Ticket`` (or anything with the same attributes); its
    ``readback`` mapping is the evidence. ``recipient`` supplies first_name/email resolved by
    the audience step. Never raises for a *content* problem: an ineligible verdict is data the
    caller records, so one bad user cannot stop a batch.
    """
    readback = dict(getattr(ticket, "readback", None) or {})
    cand = dict(getattr(ticket, "candidate", None) or {})
    cause = str(getattr(ticket, "primary_class", "other"))
    plan = str(cand.get("plan") or "")
    reason = str(cand.get("reason") or "")
    annual = "annual" in plan.lower()
    regional = "regional" in str(cand.get("discount") or "").lower()
    noun = plan_noun(plan, policy)
    ended = date_words(float(getattr(ticket, "cancel_at", 0.0) or 0.0))
    try:
        fix_line, notes = fix_line_for(cause, readback, policy, human_reply=human_reply)
        offer_line, coupon, offer_url = offer_for(reason, annual=annual, regional=regional,
                                                  policy=policy, plan=plan,
                                                  regional_coupon=regional_coupon)
        template = policy.get("template") or {}
        values = {
            "first_name": first_name((recipient or {}).get("first_name")),
            "cause_noun": str((policy.get("cause_nouns") or {}).get(cause) or "your message"),
            "fix_line": fix_line,
            "plan_noun": noun,
            "pro_ended_date": ended,
            "offer_line": offer_line,
        }
        body = "\n\n".join(str(par).format(**values) for par in (template.get("body") or []))
        subject = str(template.get("subject") or "").format(**values)
        left = _PLACEHOLDER.findall(f"{subject}\n{body}")
        if left:
            raise PolicyGap(f"unfilled placeholders in the rendered body: {sorted(set(left))}")
    except (RenderRefused, KeyError) as exc:
        fixable = not isinstance(exc, RenderRefused) or isinstance(exc, PolicyGap)
        return Rendered(
            user_id=str(getattr(ticket, "user_id", "")), subject="", body="", variant=cause,
            fix_line="", offer_line="", coupon=None, plan_noun=noun, pro_ended_date=ended,
            ineligible_reason=(str(exc) if isinstance(exc, RenderRefused)
                               else f"the template asks for a value the policy does not hold: {exc}"),
            ineligible_fixable=fixable,
        )

    if regional:
        notes.append("regional discount: country coupon kept, regional sentence "
                     + ("added under offers.regional_suffix.fable_go_ref"
                        if regional_coupon == coupons.HELD
                        else f"dropped (coupon {regional_coupon or coupons.UNVERIFIED} at send)"))
    return Rendered(
        user_id=str(getattr(ticket, "user_id", "")),
        subject=subject,
        body=body,
        variant=cause,
        fix_line=fix_line,
        offer_line=offer_line,
        coupon=coupon,
        offer_url=offer_url,
        plan_noun=noun,
        pro_ended_date=ended,
        notes=notes,
    )
