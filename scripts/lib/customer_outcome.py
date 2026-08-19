"""Machine-readable customer outcome contract for ClickUp User Requests.

Workflow status answers whether internal work stopped.  These namespaced tags
answer whether the exact customer-visible result is safe to describe as done.
Consumers fail closed when the tag is absent, invalid, or ambiguous.
"""

from __future__ import annotations


OUTCOME_TAG_PREFIX = "customer-outcome:"
OUTCOME_COMPLETE = "complete"
VALID_OUTCOMES = frozenset({
    OUTCOME_COMPLETE,
    "partial",
    "needs-customer",
    "blocked",
    "verification-required",
    "not-applicable",
})


def _tag_names(task: dict) -> set[str]:
    return {
        str(tag.get("name", "")).strip().lower()
        for tag in task.get("tags") or []
        if isinstance(tag, dict)
    }


def outcome_tags_of(task: dict) -> set[str]:
    """Return every namespaced outcome tag, including invalid ones."""
    return {name for name in _tag_names(task) if name.startswith(OUTCOME_TAG_PREFIX)}


def customer_outcome_of(task: dict) -> str | None:
    """Return the one valid outcome, or None when missing/invalid/ambiguous."""
    tags = outcome_tags_of(task)
    if len(tags) != 1:
        return None
    outcome = next(iter(tags)).removeprefix(OUTCOME_TAG_PREFIX)
    return outcome if outcome in VALID_OUTCOMES else None


def workflow_terminal(task: dict) -> bool:
    """Whether ClickUp considers work terminal, independent of customer outcome."""
    status = task.get("status") or {}
    name = str(status.get("status") or "").strip().lower()
    kind = str(status.get("type") or "").strip().lower()
    return kind in {"closed", "done"} or name in {"resolved", "impossible"}


def customer_complete(task: dict) -> bool:
    """True only for a terminal, non-impossible task explicitly marked complete."""
    status_name = str((task.get("status") or {}).get("status") or "").strip().lower()
    return (
        status_name != "impossible"
        and workflow_terminal(task)
        and customer_outcome_of(task) == OUTCOME_COMPLETE
    )


def outcome_tag(outcome: str) -> str:
    normalized = str(outcome).strip().lower()
    if normalized not in VALID_OUTCOMES:
        raise ValueError(f"unknown customer outcome: {outcome}")
    return f"{OUTCOME_TAG_PREFIX}{normalized}"
