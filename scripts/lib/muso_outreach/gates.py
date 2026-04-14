"""Precondition gates A–G. Each is a pure function that returns a
GateResult. No I/O here — adapters fetch the data and pass it in.
"""
from __future__ import annotations

from typing import Optional

from .types import ContactRow, Draft, GateResult, Kind, Metadata, Thread

RECIPIENT_MISMATCH = "RECIPIENT_MISMATCH"
RECIPIENT_SOURCE_MISSING = "RECIPIENT_SOURCE_MISSING"


def _norm(addr: str) -> str:
    return addr.strip().lower()


def _first_outgoing_muso(thread: Thread, muso_domain: str = "@muso.ai") -> Optional[object]:
    for msg in thread.messages:
        if _norm(msg.from_addr).endswith(muso_domain):
            return msg
    return None


def gate_a_recipient_match(
    draft: Draft,
    meta: Metadata,
    thread: Optional[Thread],
    contact_row: Optional[ContactRow],
) -> GateResult:
    # Override escape hatch (design §5).
    if meta.override_reason:
        return GateResult(passed=True)

    if len(draft.to_addrs) != 1:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_MISMATCH,
            reason_human=(
                f"Draft must have exactly one To: recipient; got "
                f"{len(draft.to_addrs)}: {draft.to_addrs}"
            ),
        )

    draft_to = _norm(draft.to_addrs[0])

    if meta.kind is Kind.NEW:
        if contact_row is None or not contact_row.valid_professional_email:
            return GateResult(
                passed=False,
                reason_code=RECIPIENT_SOURCE_MISSING,
                reason_human=(
                    f"Sheet row {meta.sheet_row_id} has no valid_professional_email. "
                    "Update the sheet or drop this draft."
                ),
            )
        expected = _norm(contact_row.valid_professional_email)
        if draft_to != expected:
            return GateResult(
                passed=False,
                reason_code=RECIPIENT_MISMATCH,
                reason_human=(
                    f"Draft To: {draft.to_addrs[0]} does not match sheet "
                    f"{contact_row.valid_professional_email}. Likely hallucination."
                ),
            )
        return GateResult(passed=True)

    # kind == FOLLOWUP
    if thread is None or not thread.messages:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"No thread {meta.original_thread_id} or thread is empty."
            ),
        )
    first_out = _first_outgoing_muso(thread)
    if first_out is None:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"Thread {meta.original_thread_id} has no outgoing @muso.ai "
                f"message — cannot determine original recipient."
            ),
        )
    if len(first_out.to_addrs) != 1:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"First outgoing message in {meta.original_thread_id} has "
                f"{len(first_out.to_addrs)} recipients; follow-up requires exactly 1."
            ),
        )
    expected = _norm(first_out.to_addrs[0])
    if draft_to != expected:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_MISMATCH,
            reason_human=(
                f"Draft To: {draft.to_addrs[0]} does not match original thread "
                f"recipient {first_out.to_addrs[0]}. Likely hallucination."
            ),
        )
    return GateResult(passed=True)


# ---------------------------------------------------------------------------
# Gate B — no contact reply
# ---------------------------------------------------------------------------

CONTACT_REPLIED = "CONTACT_REPLIED"


def _is_muso(addr: str, muso_domain: str = "@muso.ai") -> bool:
    return _norm(addr).endswith(muso_domain)


def gate_b_no_contact_reply(
    meta: Metadata,
    thread: Optional[Thread],
    inbound_messages: tuple,  # for kind=new: prior messages from target contact
) -> GateResult:
    if meta.kind is Kind.FOLLOWUP:
        if thread is None:
            return GateResult(passed=True)
        for msg in thread.messages:
            if not _is_muso(msg.from_addr):
                return GateResult(
                    passed=False,
                    reason_code=CONTACT_REPLIED,
                    reason_human=(
                        f"Contact replied in thread {meta.original_thread_id} "
                        f"at epoch {msg.date_epoch}. Move GHL to Replied manually."
                    ),
                )
        return GateResult(passed=True)

    # kind=new
    for msg in inbound_messages:
        if not _is_muso(msg.from_addr):
            return GateResult(
                passed=False,
                reason_code=CONTACT_REPLIED,
                reason_human=(
                    f"Prior inbound message from target "
                    f"{msg.from_addr} at epoch {msg.date_epoch} — do not cold-email again."
                ),
            )
    return GateResult(passed=True)
