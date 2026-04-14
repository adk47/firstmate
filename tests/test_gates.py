"""Tests for precondition gates A–G. See design spec §3."""
from __future__ import annotations

from scripts.lib.muso_outreach.gates import (
    RECIPIENT_MISMATCH,
    RECIPIENT_SOURCE_MISSING,
    gate_a_recipient_match,
)
from scripts.lib.muso_outreach.types import Kind
from tests.conftest import (
    make_contact_row, make_draft, make_message, make_metadata, make_thread,
)


# -------- Gate A: kind=new --------

def test_gate_a_new_matches_sheet_email_case_insensitive():
    draft = make_draft(to=("OW@LarsenStrings.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="ow@larsenstrings.com")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert result.passed, result.reason_human


def test_gate_a_new_hallucinated_domain_blocks():
    draft = make_draft(to=("ow@lfrequencies.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="ow@larsenstrings.com")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert not result.passed
    assert result.reason_code == RECIPIENT_MISMATCH
    assert "ow@lfrequencies.com" in result.reason_human
    assert "ow@larsenstrings.com" in result.reason_human


def test_gate_a_new_sheet_email_blank_blocks():
    draft = make_draft(to=("ow@larsenstrings.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert not result.passed
    assert result.reason_code == RECIPIENT_SOURCE_MISSING


# -------- Gate A: kind=followup --------

def test_gate_a_followup_matches_first_outgoing_muso_message():
    thread = make_thread(messages=(
        make_message(message_id="m1", from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
        make_message(message_id="m2", from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
    ))
    draft = make_draft(to=("ow@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed


def test_gate_a_followup_inbound_initiated_thread_uses_second_message():
    """Thread started by the contact; our reply is the second message.
    Gate A must compare the draft against the To: of our reply, not
    the original inbound message's To: (which would be @muso.ai)."""
    thread = make_thread(messages=(
        make_message(message_id="m1", from_addr="ole@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=100),
        make_message(message_id="m2", from_addr="a@muso.ai",
                     to_addrs=("ole@larsenstrings.com",), date_epoch=200),
    ))
    draft = make_draft(to=("ole@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed


def test_gate_a_followup_hallucinated_domain_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    draft = make_draft(to=("ow@lfrequencies.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert not result.passed
    assert result.reason_code == RECIPIENT_MISMATCH


def test_gate_a_followup_no_outgoing_muso_message_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="ole@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=100),
    ))
    draft = make_draft(to=("ole@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert not result.passed
    assert result.reason_code == RECIPIENT_SOURCE_MISSING


def test_gate_a_override_reason_bypasses_mismatch():
    """Only gate A can be overridden. With override_reason set, a
    mismatched recipient is allowed through (send -> worker logs override)."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    draft = make_draft(to=("o.wichmann@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1",
                         override_reason="Contact asked us to CC their assistant")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed


# -------- Gate B: no contact reply --------

from scripts.lib.muso_outreach.gates import (
    CONTACT_REPLIED, gate_b_no_contact_reply,
)


def test_gate_b_followup_no_inbound_reply_passes():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread, inbound_messages=(),
                                     bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_b_followup_contact_replied_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
        make_message(from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread, inbound_messages=(),
                                     bot_senders=("a@muso.ai",))
    assert not result.passed
    assert result.reason_code == CONTACT_REPLIED


def test_gate_b_followup_inbound_initiated_no_contact_reply_passes():
    """Thread started by contact; our reply is the second message. The
    contact's initial message is BEFORE our first send, so it is NOT a
    'reply to our outreach.' Gate B must not block on it."""
    thread = make_thread(messages=(
        make_message(from_addr="ole@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=100),  # inbound first
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ole@larsenstrings.com",), date_epoch=200),  # our outreach
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread,
                                     inbound_messages=(),
                                     bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_b_followup_contact_replied_AFTER_bot_blocks():
    """Contact replied after our outreach -- real reply, block."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),  # our send
        make_message(from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),  # contact reply
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread,
                                     inbound_messages=(),
                                     bot_senders=("a@muso.ai",))
    assert not result.passed
    assert result.reason_code == CONTACT_REPLIED


def test_gate_b_new_no_inbound_from_contact_passes():
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    result = gate_b_no_contact_reply(meta, thread=None, inbound_messages=())
    assert result.passed


def test_gate_b_new_contact_already_emailed_blocks():
    # For kind=new, the adapter fetches any recent messages from the
    # target contact across all muso accounts and passes them in.
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    prior = (make_message(from_addr="prospect@acme.com",
                          to_addrs=("a@muso.ai",), date_epoch=100),)
    result = gate_b_no_contact_reply(meta, thread=None, inbound_messages=prior)
    assert not result.passed
    assert result.reason_code == CONTACT_REPLIED


# -------- Gate C: no human-teammate reply --------

from scripts.lib.muso_outreach.gates import (
    HUMAN_TEAMMATE_REPLIED, gate_c_no_human_reply,
)


def test_gate_c_only_bot_sender_in_thread_passes():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),
        make_message(from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
        make_message(from_addr="a@muso.ai", date_epoch=300),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    # Gate C looks at muso.ai messages AFTER the last bot-sender message.
    # Here the last bot-sender msg is at 300 and nothing follows.
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_c_human_teammate_replied_blocks():
    """Aaron (a human on the team) replied from aaron.k@muso.ai after
    the bot's last send. Bot must stand down."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),  # bot
        make_message(from_addr="aaron.k@muso.ai", date_epoch=200),  # human
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert not result.passed
    assert result.reason_code == HUMAN_TEAMMATE_REPLIED
    assert "aaron.k@muso.ai" in result.reason_human


def test_gate_c_bot_resend_not_flagged_as_human():
    """Multiple bot messages in sequence do not trigger the gate."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),
        make_message(from_addr="a@muso.ai", date_epoch=200),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_c_new_kind_skipped():
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    result = gate_c_no_human_reply(meta, thread=None, bot_senders=("a@muso.ai",))
    assert result.passed


# -------- Gates D, E, F, G --------

from scripts.lib.muso_outreach.gates import (
    FOLLOWUP_CAP_REACHED,
    SENDER_NOT_ALLOWED,
    UNEXPECTED_CC_BCC,
    WEEKEND_BLOCKED,
    gate_d_not_weekend,
    gate_e_followup_cap,
    gate_f_sender_allowed,
    gate_g_cc_bcc_match_allowlist,
)


# Gate D
def test_gate_d_monday_passes():
    # 2026-04-13 is a Monday (UTC).
    assert gate_d_not_weekend(epoch=1776096000).passed


def test_gate_d_saturday_blocks():
    # 2026-04-11 is a Saturday (UTC).
    r = gate_d_not_weekend(epoch=1775923200)
    assert not r.passed
    assert r.reason_code == WEEKEND_BLOCKED


def test_gate_d_sunday_blocks():
    # 2026-04-12 is a Sunday (UTC).
    r = gate_d_not_weekend(epoch=1776009600)
    assert not r.passed
    assert r.reason_code == WEEKEND_BLOCKED


# Gate E
def test_gate_e_under_cap_passes():
    assert gate_e_followup_cap(prior_followup_count=2).passed


def test_gate_e_at_cap_blocks():
    r = gate_e_followup_cap(prior_followup_count=3)
    assert not r.passed
    assert r.reason_code == FOLLOWUP_CAP_REACHED


# Gate F
def test_gate_f_allowed_sender_passes():
    draft = make_draft(account="a@muso.ai")
    meta = make_metadata(sender="a@muso.ai")
    assert gate_f_sender_allowed(draft, meta,
                                 allow_list=frozenset({"a@muso.ai"})).passed


def test_gate_f_draft_from_non_allowed_account_blocks():
    draft = make_draft(account="random@elsewhere.com")
    meta = make_metadata(sender="a@muso.ai")
    r = gate_f_sender_allowed(draft, meta,
                              allow_list=frozenset({"a@muso.ai"}))
    assert not r.passed
    assert r.reason_code == SENDER_NOT_ALLOWED


def test_gate_f_draft_account_mismatches_metadata_sender_blocks():
    """The draft's actual sending account must agree with what the
    agent declared in metadata."""
    draft = make_draft(account="ak@muso.ai")
    meta = make_metadata(sender="a@muso.ai")
    r = gate_f_sender_allowed(draft, meta,
                              allow_list=frozenset({"a@muso.ai", "ak@muso.ai"}))
    assert not r.passed
    assert r.reason_code == SENDER_NOT_ALLOWED


# Gate G
def test_gate_g_no_cc_bcc_passes():
    draft = make_draft(cc=(), bcc=())
    meta = make_metadata(cc_allowlist=(), bcc_allowlist=())
    assert gate_g_cc_bcc_match_allowlist(draft, meta).passed


def test_gate_g_unexpected_cc_blocks():
    draft = make_draft(cc=("assistant@larsenstrings.com",))
    meta = make_metadata(cc_allowlist=())
    r = gate_g_cc_bcc_match_allowlist(draft, meta)
    assert not r.passed
    assert r.reason_code == UNEXPECTED_CC_BCC


def test_gate_g_explicit_cc_allowlist_passes():
    draft = make_draft(cc=("assistant@larsenstrings.com",))
    meta = make_metadata(cc_allowlist=("assistant@larsenstrings.com",))
    assert gate_g_cc_bcc_match_allowlist(draft, meta).passed


def test_gate_g_unexpected_bcc_blocks():
    draft = make_draft(bcc=("sneak@example.com",))
    meta = make_metadata()
    r = gate_g_cc_bcc_match_allowlist(draft, meta)
    assert not r.passed
    assert r.reason_code == UNEXPECTED_CC_BCC
