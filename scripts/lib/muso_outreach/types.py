"""Domain dataclasses used by the outreach sender worker.

Adapters (gmail_client, sheets_client) build these from gog CLI output;
gates and worker operate on them. This keeps side effects out of the
logic layer so the gates can be unit-tested without gog installed.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class Kind(str, Enum):
    FOLLOWUP = "followup"
    NEW = "new"


@dataclass(frozen=True)
class Message:
    message_id: str
    thread_id: str
    from_addr: str
    to_addrs: tuple[str, ...]
    cc_addrs: tuple[str, ...]
    bcc_addrs: tuple[str, ...]
    date_epoch: int  # UTC seconds


@dataclass(frozen=True)
class Thread:
    thread_id: str
    messages: tuple[Message, ...]  # oldest → newest


@dataclass(frozen=True)
class Draft:
    draft_id: str
    account: str  # e.g., "a@muso.ai"
    to_addrs: tuple[str, ...]
    cc_addrs: tuple[str, ...]
    bcc_addrs: tuple[str, ...]
    body_html: str
    labels: tuple[str, ...]
    reply_to_message_id: Optional[str]  # Gmail In-Reply-To header


@dataclass(frozen=True)
class ContactRow:
    row_id: str
    valid_professional_email: str  # may be empty


@dataclass(frozen=True)
class NocoContact:
    """One Contacts Intelligence record as read from NocoDB."""
    nocodb_id: int
    row_id: str
    valid_professional_email: str  # may be empty
    status: str  # e.g. "Follow Up 2"; may be empty


@dataclass(frozen=True)
class Metadata:
    kind: Kind
    opp_id: Optional[str]  # required for followup; a NEW contact has no opp yet
    template: str
    sender: str  # muso.ai account
    original_thread_id: Optional[str]  # followup only
    # Exactly one key shape is set: nocodb_id (+ row_id) is the NocoDB
    # contact; sheet_row_id is the legacy int row of the retired sheet tab.
    nocodb_id: Optional[int] = None
    row_id: Optional[str] = None
    sheet_row_id: Optional[int] = None
    override_reason: Optional[str] = None
    cc_allowlist: tuple[str, ...] = field(default_factory=tuple)
    bcc_allowlist: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class GateResult:
    passed: bool
    reason_code: Optional[str] = None  # e.g., "RECIPIENT_MISMATCH"
    reason_human: Optional[str] = None
