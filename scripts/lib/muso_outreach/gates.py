"""Precondition gates A–G. Each is a pure function that returns a
GateResult. No I/O here — adapters fetch the data and pass it in.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from .config import OVERRIDE_APPROVED_LABEL
from .types import ContactRow, Draft, GateResult, Kind, Metadata, Thread

RECIPIENT_MISMATCH = "RECIPIENT_MISMATCH"
RECIPIENT_SOURCE_MISSING = "RECIPIENT_SOURCE_MISSING"


def _norm(addr: str) -> str:
    return addr.strip().lower()


def _email_domain(addr: str) -> str:
    """Return the domain part of an email address, lower-cased.

    Uses split('@', 1) so the comparison is exact — 'sub.muso.ai' does NOT
    match 'muso.ai'. endswith('@muso.ai') would also be exact here (the '@'
    anchors it), but explicit split is clearer and easier to audit.
    """
    parts = _norm(addr).rsplit("@", 1)
    return parts[-1] if len(parts) == 2 else ""


MUSO_DOMAIN = "muso.ai"


def _first_outgoing_muso(thread: Thread) -> Optional[object]:
    for msg in thread.messages:
        if _email_domain(msg.from_addr) == MUSO_DOMAIN:
            return msg
    return None


def gate_a_recipient_match(
    draft: Draft,
    meta: Metadata,
    thread: Optional[Thread],
    contact_row: Optional[ContactRow],
) -> GateResult:
    # Override escape hatch (design §5). Requires BOTH:
    #   - override_reason in metadata (agent-written, reviewable)
    #   - OVERRIDE_APPROVED_LABEL on the draft (human-applied after review)
    # The label alone or the reason alone is not enough — the JSON
    # comment is agent-editable, so the label is the human-gated half.
    if meta.override_reason and OVERRIDE_APPROVED_LABEL in draft.labels:
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


def _is_muso(addr: str) -> bool:
    return _email_domain(addr) == MUSO_DOMAIN


def gate_b_no_contact_reply(
    meta: Metadata,
    thread: Optional[Thread],
    inbound_messages: tuple,  # for kind=new: prior messages from target contact
    bot_senders: tuple[str, ...] = (),
) -> GateResult:
    if meta.kind is Kind.FOLLOWUP:
        if thread is None:
            return GateResult(passed=True)
        bot_set = {_norm(s) for s in bot_senders}
        # Find bot's last send; only messages AFTER it count as "reply".
        last_bot_epoch = -1
        for msg in thread.messages:
            if _norm(msg.from_addr) in bot_set:
                last_bot_epoch = max(last_bot_epoch, msg.date_epoch)
        if last_bot_epoch < 0:
            # Bot hasn't sent yet -- nothing to reply to. Gate B abstains.
            return GateResult(passed=True)
        for msg in thread.messages:
            if msg.date_epoch <= last_bot_epoch:
                continue
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


# ---------------------------------------------------------------------------
# Gate C — no human-teammate reply
# ---------------------------------------------------------------------------

HUMAN_TEAMMATE_REPLIED = "HUMAN_TEAMMATE_REPLIED"


def gate_c_no_human_reply(
    meta: Metadata,
    thread: Optional[Thread],
    bot_senders: tuple[str, ...],
) -> GateResult:
    """Block if any muso.ai address that is NOT the bot sender has a
    message in the thread after the bot's last send. Only applies to
    followups."""
    if meta.kind is Kind.NEW or thread is None:
        return GateResult(passed=True)

    bot_set = {_norm(s) for s in bot_senders}
    last_bot_epoch = -1
    for msg in thread.messages:
        if _norm(msg.from_addr) in bot_set:
            last_bot_epoch = max(last_bot_epoch, msg.date_epoch)

    if last_bot_epoch < 0:
        # No bot messages yet — nothing to follow up on. Gate C abstains.
        return GateResult(passed=True)

    for msg in thread.messages:
        if msg.date_epoch <= last_bot_epoch:
            continue
        if _is_muso(msg.from_addr) and _norm(msg.from_addr) not in bot_set:
            return GateResult(
                passed=False,
                reason_code=HUMAN_TEAMMATE_REPLIED,
                reason_human=(
                    f"Human teammate {msg.from_addr} replied in thread "
                    f"{meta.original_thread_id} after the bot's last send. "
                    "Bot stands down."
                ),
            )
    return GateResult(passed=True)


# ---------------------------------------------------------------------------
# Gate D — not weekend
# ---------------------------------------------------------------------------

WEEKEND_BLOCKED = "WEEKEND_BLOCKED"


def gate_d_not_weekend(epoch: int) -> GateResult:
    """Saturday=5, Sunday=6 in Python's weekday()."""
    dow = datetime.fromtimestamp(epoch, tz=timezone.utc).weekday()
    if dow >= 5:
        return GateResult(
            passed=False,
            reason_code=WEEKEND_BLOCKED,
            reason_human="Weekend send blocked per outreach policy. Push to Monday.",
        )
    return GateResult(passed=True)


# ---------------------------------------------------------------------------
# Gate E — followup cap
# ---------------------------------------------------------------------------

FOLLOWUP_CAP_REACHED = "FOLLOWUP_CAP_REACHED"


def gate_e_followup_cap(prior_followup_count: int,
                        cap: int = 3) -> GateResult:
    if prior_followup_count >= cap:
        return GateResult(
            passed=False,
            reason_code=FOLLOWUP_CAP_REACHED,
            reason_human=(
                f"Already sent {prior_followup_count} follow-ups; cap is {cap}."
            ),
        )
    return GateResult(passed=True)


# ---------------------------------------------------------------------------
# Gate F — sender allowed
# ---------------------------------------------------------------------------

SENDER_NOT_ALLOWED = "SENDER_NOT_ALLOWED"


def gate_f_sender_allowed(
    draft: Draft,
    meta: Metadata,
    allow_list: frozenset[str],
) -> GateResult:
    draft_account = _norm(draft.account)
    meta_sender = _norm(meta.sender)
    allowed = {_norm(a) for a in allow_list}
    if draft_account not in allowed:
        return GateResult(
            passed=False,
            reason_code=SENDER_NOT_ALLOWED,
            reason_human=(
                f"Draft account {draft.account} is not in the outreach "
                f"sender allow-list {sorted(allow_list)}."
            ),
        )
    if draft_account != meta_sender:
        return GateResult(
            passed=False,
            reason_code=SENDER_NOT_ALLOWED,
            reason_human=(
                f"Draft account {draft.account} disagrees with metadata "
                f"sender {meta.sender}. Precision mismatch."
            ),
        )
    return GateResult(passed=True)


# ---------------------------------------------------------------------------
# Gate G — CC/BCC match allowlist
# ---------------------------------------------------------------------------

UNEXPECTED_CC_BCC = "UNEXPECTED_CC_BCC"


def gate_g_cc_bcc_match_allowlist(
    draft: Draft,
    meta: Metadata,
) -> GateResult:
    cc_allow = {_norm(a) for a in meta.cc_allowlist}
    bcc_allow = {_norm(a) for a in meta.bcc_allowlist}
    extra_cc = [a for a in draft.cc_addrs if _norm(a) not in cc_allow]
    extra_bcc = [a for a in draft.bcc_addrs if _norm(a) not in bcc_allow]
    if extra_cc or extra_bcc:
        return GateResult(
            passed=False,
            reason_code=UNEXPECTED_CC_BCC,
            reason_human=(
                f"Unexpected CC: {extra_cc} / BCC: {extra_bcc}. "
                "Refusing to send."
            ),
        )
    return GateResult(passed=True)
