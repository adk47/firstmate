"""At-send re-check that a Regional Discount user still holds their country coupon.

The Fable owner's GO (fable-ruling-1104-d2/wbfix1-regional-suffix) allows the regional sentence
ONLY for users who still hold the coupon at send time. The candidate snapshot is from list build,
so it cannot answer that: a coupon can lapse in between, and the sentence asserts a price.

    HELD        a live discount exists whose coupon id or name matches the recorded discount
    LAPSED      the read succeeded and shows no such discount
    UNVERIFIED  the read failed, the CLI is absent, or the shapes are ambiguous

Only HELD appends the sentence. LAPSED and UNVERIFIED drop it and the message still sends: a
Stripe outage must never block a message and must never produce a false price statement.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from typing import Any, Callable, Mapping

HELD = "held"
LAPSED = "lapsed"
UNVERIFIED = "unverified"

#: The Stripe CLI, overridable the same way the rest of the fleet overrides it.
STRIPE_BIN = "STRIPE_BIN"
TIMEOUT_SECONDS = 20


def _stripe(args: list[str]) -> Mapping[str, Any] | None:
    """One bounded Stripe CLI read as JSON, or None when it cannot be read."""
    cmd = [os.environ.get(STRIPE_BIN) or "stripe", *args]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        doc = json.loads(proc.stdout)
    except ValueError:
        return None
    return doc if isinstance(doc, dict) else None


def offline(args: list[str]) -> Mapping[str, Any] | None:
    """A rehearsal never calls Stripe: the verdict is UNVERIFIED, so the sentence is dropped."""
    return None


def _discounts(doc: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """Every discount object in a customer or subscription-list payload."""
    out: list[Mapping[str, Any]] = []
    direct = doc.get("discount")
    if isinstance(direct, Mapping):
        out.append(direct)
    for key in ("subscriptions", "data"):
        block = doc.get(key)
        items = block.get("data") if isinstance(block, Mapping) else block
        for item in items or []:
            if isinstance(item, Mapping) and isinstance(item.get("discount"), Mapping):
                out.append(item["discount"])
    return out


_PUNCTUATION = re.compile(r"[^\w\s]")


def _norm(value: Any) -> str:
    return " ".join(_PUNCTUATION.sub(" ", str(value or "")).split()).lower()


def _matches(discount: Mapping[str, Any], recorded: str) -> bool:
    """A live discount whose coupon id or name IS the regional discount we recorded.

    Exact after normalisation, never a substring: a live coupon named "Regional" is not evidence
    that the recorded "Regional Discount 40%" still applies, and HELD is the only verdict that
    ships a price statement.
    """
    coupon = discount.get("coupon")
    if not isinstance(coupon, Mapping):
        return False
    want = _norm(recorded)
    if not want:
        return False
    return any(_norm(raw) == want for raw in (coupon.get("id"), coupon.get("name")) if _norm(raw))


def _verdict(run: Callable[[list[str]], Mapping[str, Any] | None], customer_id: str,
             recorded: str) -> str:
    if not customer_id or not recorded:
        return UNVERIFIED
    doc = run(["customers", "retrieve", customer_id])
    if doc is None:
        return UNVERIFIED
    discounts = _discounts(doc)
    if not discounts:
        subs = run(["subscriptions", "list", "-d", f"customer={customer_id}", "-d", "status=all",
                    "--limit", "1"])
        if subs is None:
            return UNVERIFIED
        discounts = _discounts(subs)
    return HELD if any(_matches(d, recorded) for d in discounts) else LAPSED


class CouponCheck:
    """One bounded read per customer, cached for the run."""

    def __init__(self, run: Callable[[list[str]], Mapping[str, Any] | None] | None = None):
        self._run = run or _stripe
        self._cache: dict[tuple[str, str], str] = {}

    def verdict(self, customer_id: Any, recorded: Any) -> str:
        key = (str(customer_id or "").strip(), str(recorded or "").strip())
        if key not in self._cache:
            self._cache[key] = _verdict(self._run, *key)
        return self._cache[key]
