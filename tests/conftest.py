"""Shared fixtures for gate tests.

Builds domain objects directly — no gog, no Gmail, no network.
"""
from __future__ import annotations

from scripts.lib.muso_outreach.types import (
    ContactRow, Draft, Kind, Message, Metadata, NocoContact, Thread,
)


def make_draft(
    draft_id: str = "r1",
    account: str = "a@muso.ai",
    to: tuple[str, ...] = ("ow@larsenstrings.com",),
    cc: tuple[str, ...] = (),
    bcc: tuple[str, ...] = (),
    body_html: str = "",
    labels: tuple[str, ...] = (),
    reply_to: str | None = None,
) -> Draft:
    return Draft(draft_id, account, to, cc, bcc, body_html, labels, reply_to)


def make_message(
    message_id: str = "m1",
    thread_id: str = "t1",
    from_addr: str = "a@muso.ai",
    to_addrs: tuple[str, ...] = ("ow@larsenstrings.com",),
    cc_addrs: tuple[str, ...] = (),
    bcc_addrs: tuple[str, ...] = (),
    date_epoch: int = 0,
) -> Message:
    return Message(message_id, thread_id, from_addr, to_addrs,
                   cc_addrs, bcc_addrs, date_epoch)


def make_thread(thread_id: str = "t1", messages: tuple[Message, ...] = ()) -> Thread:
    return Thread(thread_id, messages)


def make_metadata(
    kind: Kind = Kind.FOLLOWUP,
    sheet_row_id: int | None = 1234,
    opp_id: str | None = "abc",
    template: str = "FU-01",
    sender: str = "a@muso.ai",
    original_thread_id: str | None = "t1",
    override_reason: str | None = None,
    cc_allowlist: tuple[str, ...] = (),
    bcc_allowlist: tuple[str, ...] = (),
    nocodb_id: int | None = None,
    row_id: str | None = None,
) -> Metadata:
    """Legacy (sheet_row_id) shape by default; pass nocodb_id + row_id and
    sheet_row_id=None for the NocoDB shape."""
    return Metadata(kind, opp_id, template, sender, original_thread_id,
                    nocodb_id, row_id, sheet_row_id,
                    override_reason, cc_allowlist, bcc_allowlist)


def make_contact_row(
    row_id: str = "1234",
    email: str = "ow@larsenstrings.com",
) -> ContactRow:
    return ContactRow(row_id, email)


def make_noco_contact(
    nocodb_id: int = 2,
    row_id: str = "dangjf643",
    email: str = "ow@larsenstrings.com",
    status: str = "",
) -> NocoContact:
    return NocoContact(nocodb_id, row_id, email, status)
