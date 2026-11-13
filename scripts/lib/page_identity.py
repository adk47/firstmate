"""The ONE page-id identity rule: two Muso page (profile) ids denote the same page.

Equality, or one id is a truncated prefix of the other and the shorter side is at
least `MIN_PREFIX` (8) characters - never a shorter run, which would sweep in
unrelated pages. A profile id reaches us whole (`fc31a861-0297-...`) from core and
truncated (`fc31a861`) from a register row, a ticket, a pasted link or a
screenshot; both name one page.

This module is the canonical definition. `ops_intake/lens_sources.py` and
`claim_verify/doc_ladder.py` both call it; a caller that needs the rule imports it
and never spells the comparison again.

Deliberately NOT changed here: `gdpr_pipeline/store.py` `Store._prefixes` and
`gdpr-triage-bridge.py` `page_eq` key a register row by its first 8 characters
(a GROUPING key, compared by equality of the truncation). That is a different
operation on the same fact and is left with its owners.

Comparison is exact on the bytes given: a caller holding ids of mixed case
normalises them first (`norm`), so the rule itself never guesses.
"""
from __future__ import annotations

from typing import Iterable

MIN_PREFIX = 8


def norm(page_id: object) -> str:
    """The comparable spelling of an id: stripped, lower-case. '' for nothing."""
    return str(page_id or "").strip().lower()


def same_page(a: str, b: str) -> bool:
    """True when `a` and `b` name one page under the rule above. Empty never matches."""
    if not a or not b:
        return False
    if a == b:
        return True
    return min(len(a), len(b)) >= MIN_PREFIX and (a.startswith(b) or b.startswith(a))


def matched(page_id: str, asked: Iterable[str]) -> list[str]:
    """Which of the `asked` ids `page_id` answers for, in the order asked."""
    if not page_id:
        return []
    return [i for i in asked if same_page(i, page_id)]
