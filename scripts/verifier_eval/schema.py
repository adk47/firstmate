"""Item / verdict vocabulary shared by builders, verifiers and the runner.

A labelled item (one JSON object per line in ``sets/<set>.jsonl.gz``)::

    {"set": "credits" | "claims" | "merges",
     "id": "<credit request id | claim id | merge ticket id>",
     "segment": "paid" | "free" | "unknown",
     "label": "APPROVE" | "DECLINE" | "WAIT",          # the ground-truth outcome
     "approved_roles": [..] | null,                    # credits: roles the label approves
     "known_bad": bool,                                # confirmed fraud / contradicted / forged
     "label_source": "<short slug>",                   # where the label came from
     "label_strength": "human" | "audit" | "fable_handoff" | "ops_classification",
     "label_ref": "<file or ledger the label was read from>",
     "user_id": "<id>" | null,
     "evidence": {...} | null}                         # frozen inputs a verifier may read

A verifier is ``fn(item) -> Verdict`` (pure; it must not do I/O against Muso).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

APPROVE = "APPROVE"
DECLINE = "DECLINE"
WAIT = "WAIT"
UNKNOWN = "UNKNOWN"  # a verifier could not read enough evidence; scored like WAIT, never approves

LABELS = (APPROVE, DECLINE, WAIT)
VERDICTS = (APPROVE, DECLINE, WAIT, UNKNOWN)
SETS = ("credits", "claims", "merges")
SEGMENTS_ORDER = ("paid", "free", "unknown")  # paid first, always

STRENGTHS = ("human", "audit", "fable_handoff", "ops_classification")

# Popularity at/above which an approve needs two independent signals (d1 rules-for-code §1);
# the shadow guard treats any single-signal approve here as a protection violation.
BIG_POPULARITY = 60


@dataclass
class Verdict:
    verdict: str
    reasons: list[str] = field(default_factory=list)
    approved_roles: list[str] | None = None
    evidence_used: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.verdict not in VERDICTS:
            raise ValueError(f"unknown verdict {self.verdict!r}")


def validate_item(item: dict[str, Any]) -> list[str]:
    """Problems with one labelled item (empty list = valid)."""
    errs = []
    if item.get("set") not in SETS:
        errs.append(f"set={item.get('set')!r}")
    if not item.get("id"):
        errs.append("missing id")
    if item.get("label") not in LABELS:
        errs.append(f"label={item.get('label')!r}")
    if item.get("segment") not in SEGMENTS_ORDER:
        errs.append(f"segment={item.get('segment')!r}")
    if item.get("label_strength") not in STRENGTHS:
        errs.append(f"label_strength={item.get('label_strength')!r}")
    if not item.get("label_source"):
        errs.append("missing label_source")
    if item.get("known_bad") and item.get("label") == APPROVE:
        errs.append("known_bad item labelled APPROVE")
    return errs
