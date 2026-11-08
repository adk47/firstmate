"""The last code-owned gate before a win-back body is handed to the sender seat.

Deliberately small and deterministic, and deliberately NOT the Caroline output guard: that
guard exists to stop an *agent* from promising an outcome it cannot see (plugins/intercom/
caroline-output-guard.ts, family "promise"). This campaign's whole premise is the opposite -
it states a completed action, and only where a read-back proved it - so the two gates check
different things:

    guard here                          what it stops
    ----------------------------------------------------------------------------------
    forbidden vendor/source names       naming Klaviyo or Jaxsta (captain rule)
    forward-promise family              "within 24 hours" / "we will get back to you":
                                        the exact copy family that burned these users
    unfilled placeholder                a body that ships with {first_name} in it
    internal-process vocabulary         scores, thresholds, lenses, queues, ticket ids
    link hygiene                        anything that is not an https muso.ai link,
                                        and an offer that says "with this link" while
                                        carrying none
    body length                         a body that is a wall of text or a fragment

A violation REFUSES the send. It is never repaired in flight: a body that needed rewriting to
pass a guard has not been reviewed by the copy owner, and this lane has no authority to
publish copy it invented (report R6).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Mapping

#: Internal-process vocabulary. Constants, not config: a rule that can be switched off at
#: runtime is not a guard. None of these belong in a customer email for any reason.
INTERNAL_WORDS = (
    "fraud lens", "fraud-lens", "watchdog", "decider", "the decider", "credit-review",
    "credit review queue", "held row", "held rows", "lane", "ticket id", "support state",
    "churn", "win-back campaign", "winback", "holdout", "internal tool", "our pipeline",
    "the pipeline", "codex", "openrouter", "gpt-", "llm", "model scored", "priority score",
    "threshold", "signal", "backlog drain", "sweep",
)

_PLACEHOLDER = re.compile(r"\{[a-z_]+\}")
_LINK = re.compile(r"https?://([^/\s)>]+)", re.I)
_ALLOWED_HOSTS = ("muso.ai",)

#: "this link" / "here:" - the phrasing an approved offer uses when it hands over a URL.
_LINK_CLAIM = re.compile(r"\bthis link\b|\b(?:restart|come back|redeem|take it) (?:again )?here\b|\bsign in here\b", re.I)

MAX_WORDS = 220
MIN_WORDS = 40


@dataclass
class GuardResult:
    ok: bool
    violations: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def reason(self) -> str:
        return "; ".join(self.violations)

    def as_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "violations": list(self.violations), "warnings": list(self.warnings)}


def _patterns(policy: Mapping[str, Any]) -> list[str]:
    return [str(p) for p in (policy.get("guards") or {}).get("promise_patterns") or [] if str(p).strip()]


def check(text: str, policy: Mapping[str, Any], *, length: bool = True,
          link_claim: bool = True) -> GuardResult:
    """Run every deterministic rule on one body (subject + body). Returns, never raises.

    ``length=False`` skips the body-length rules so the same rule set can judge a FRAGMENT of a
    body (the campaign-owned skeleton, or the sentence quoted from a human reply). The body as a
    whole is always judged with ``length=True``; only the blame split uses fragments.

    ``link_claim=False`` skips the link-claim rule, which is BODY-scoped: it asks whether the
    offer line's URL is present, and a single quoted sentence can never carry it. Judging a
    fragment with it would blame a human's "check this link" wording for a missing URL the
    campaign owns.
    """
    body = str(text or "")
    low = body.lower()
    out = GuardResult(ok=True)

    for name in (policy.get("guards") or {}).get("forbidden_names") or []:
        if str(name).strip() and str(name).lower() in low:
            out.violations.append(f"names a forbidden vendor/source: {name}")

    for pattern in _patterns(policy):
        try:
            if re.search(pattern, body, re.I):
                out.violations.append(f"carries the forward-promise family we burned users with: /{pattern}/")
        except re.error:  # a broken policy pattern is a refusal, not a skipped rule
            out.violations.append(f"unusable promise pattern in policy: /{pattern}/")

    if _PLACEHOLDER.search(body):
        out.violations.append(f"unfilled placeholder(s): {sorted(set(_PLACEHOLDER.findall(body)))}")

    for word in INTERNAL_WORDS:
        if re.search(rf"\b{re.escape(word)}\b", low):
            out.violations.append(f"leaks internal process vocabulary: {word!r}")

    for host in _LINK.findall(body):
        if not any(host.lower() == h or host.lower().endswith("." + h) for h in _ALLOWED_HOSTS):
            out.violations.append(f"non-muso link in a customer body: {host}")

    # An offer sentence that tells the reader to use "this link" and does not carry one sends
    # them looking for something that is not there. Checked here, not only at render time,
    # because this is the gate every body passes: a policy edit cannot walk a dead offer past it.
    if link_claim and _LINK_CLAIM.search(body) and not any(
            any(host.lower() == h or host.lower().endswith("." + h) for h in _ALLOWED_HOSTS)
            for host in _LINK.findall(body)):
        out.violations.append("the offer tells the reader to use a link and the body carries no muso.ai link")

    if length:
        words = len(body.split())
        if words < MIN_WORDS:
            out.violations.append(f"body is {words} words (< {MIN_WORDS}): too thin to be a real note")
        elif words > MAX_WORDS:
            out.violations.append(f"body is {words} words (> {MAX_WORDS}): a wall of text")

    if "!!" in body or re.search(r"\b(?:FREE|URGENT|ACT NOW)\b", body):
        out.warnings.append("shouty marketing phrasing")

    out.ok = not out.violations
    return out


def check_rendered(rendered: Any, policy: Mapping[str, Any]) -> GuardResult:
    """Guard a ``churn.render.Rendered`` (subject + body) as one text."""
    return check(f"{getattr(rendered, 'subject', '')}\n{getattr(rendered, 'body', '')}", policy)


def quoted_fragment_fault(rendered: Any, policy: Mapping[str, Any]) -> str | None:
    """Why this USER's quoted reply alone is unsendable, or None when the fault is the copy.

    Cause class ``other`` is the one body that carries user data verbatim (the sentence a human
    already sent them in Intercom). A violation whose trigger lives inside that quote is a
    property of that answer, not of the campaign copy, so it must never refuse everybody else's
    batch: the campaign-owned skeleton is judged on its own first, and only a quote that breaks a
    rule on its own is blamed on the user.
    """
    quote = str(getattr(rendered, "fix_line", "") or "")
    if str(getattr(rendered, "variant", "")) != "other" or not quote:
        return None
    body = str(getattr(rendered, "body", "") or "")
    if quote not in body:
        return None
    skeleton = f"{getattr(rendered, 'subject', '')}\n{body.replace(quote, '')}"
    if not check(skeleton, policy, length=False).ok:
        return None
    if check(quote, policy, length=False, link_claim=False).ok:
        return None
    return "the human answer we would quote names something we cannot send"
