"""THE send order of every outbound audience list: paying users first, the longest wait first, the user id last.

Every builder that writes a USER-level list the outbound tick walks (owing_proof, need_asks, receipts,
reply_due_scan, paid_band_ask) sorts with `key()`. The order is decided HERE, when the list is built - never at send
time, and never by the order a query or a dict happened to return its rows in. `claim_list` is not one of them: its
list is computed per CLAIM (one audience per user) by its own total key ending in `claim_id`.

Before 2026-11-12 each builder carried its own `(not paid, waited)` lambda. Paid-first was explicit and tested, but the
key stopped there: two users with the same wait kept whatever order the source handed them (Python's sort is stable),
and Trino returns rows without an ORDER BY in no promised order. The same inputs could therefore write two different
lists, and a page cursor counts entries of that list. The user id is the last word now, so the order is total.

`paid` is the flag the builder put on the row; this module never reads a subscription. A checker that asks whether a
send went paid-first has to use that same flag (the list's), or it measures a different question.
"""
from __future__ import annotations

from typing import Any

AT_RISK, PAID, FREE = 0, 1, 2     # Fable [key=pro-at-risk]: a paying user with a churn signal leads the paying tier


def tier(paid: Any, at_risk: Any = False) -> int:
    return FREE if not paid else AT_RISK if at_risk else PAID


def _uid(user_id: Any) -> tuple[int, int, str]:
    s = str(user_id)
    return (0, int(s), "") if s.isdigit() else (1, 0, s)     # a non-numeric id still sorts, after every numeric one


def key(*, paid: Any, waiting_since: Any, user_id: Any, at_risk: Any = False) -> tuple[Any, ...]:
    """Sort key: (tier, waiting_since ascending = oldest first, user id). `waiting_since` is compared as given, so one
    list must use one type for it (every builder passes its own single field)."""
    return (tier(paid, at_risk), waiting_since, _uid(user_id))
