"""Gog-CLI adapter for Gmail operations. Each function returns a
domain object (or raises on CLI failure) with no side effects other
than the underlying gog call.
"""
from __future__ import annotations

import json
import subprocess
from typing import Optional

from .types import Draft, Message, Thread


def _run_gog(*args: str) -> str:
    """Run a gog command and return stdout. Raise CalledProcessError on
    non-zero exit."""
    res = subprocess.run(
        ("gog", *args),
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return res.stdout


def _parse_message(js: dict) -> Message:
    return Message(
        message_id=js["id"],
        thread_id=js["threadId"],
        from_addr=js["from"],
        to_addrs=tuple(js.get("to") or ()),
        cc_addrs=tuple(js.get("cc") or ()),
        bcc_addrs=tuple(js.get("bcc") or ()),
        date_epoch=int(js["internalDate"]) // 1000,
    )


def fetch_draft(draft_id: str, account: str) -> Draft:
    out = _run_gog("gmail", "drafts", "get", draft_id, "--account", account, "--json")
    js = json.loads(out)
    return Draft(
        draft_id=js["id"],
        account=account,
        to_addrs=tuple(js.get("to") or ()),
        cc_addrs=tuple(js.get("cc") or ()),
        bcc_addrs=tuple(js.get("bcc") or ()),
        body_html=js.get("bodyHtml", ""),
        labels=tuple(js.get("labels") or ()),
        reply_to_message_id=js.get("inReplyTo"),
    )


def fetch_thread(thread_id: str, account: str) -> Thread:
    out = _run_gog("gmail", "threads", "get", thread_id,
                   "--account", account, "--json")
    js = json.loads(out)
    msgs = tuple(_parse_message(m) for m in js.get("messages", []))
    return Thread(thread_id=thread_id, messages=msgs)


def list_drafts_with_label(label: str, account: str) -> list[str]:
    out = _run_gog("gmail", "drafts", "list",
                   "--label", label, "--account", account, "--json")
    js = json.loads(out)
    return [d["id"] for d in js.get("drafts", [])]


def send_draft(draft_id: str, account: str) -> str:
    """Returns the message_id of the sent message."""
    out = _run_gog("gmail", "drafts", "send", draft_id,
                   "--account", account, "--json")
    js = json.loads(out)
    return js["id"]


def apply_label(message_id: str, label: str, account: str) -> None:
    _run_gog("gmail", "messages", "modify", message_id,
             "--add", label, "--account", account)


def search_inbound_from(email: str, days: int, accounts: tuple[str, ...]) -> tuple[Message, ...]:
    """Search all muso accounts for messages FROM `email` in the last N days.
    Returns Messages across all accounts (de-duped by message_id)."""
    seen: dict[str, Message] = {}
    for acct in accounts:
        query = f"from:{email} newer_than:{days}d"
        out = _run_gog("gmail", "messages", "search", query,
                       "--account", acct, "--json")
        js = json.loads(out)
        for m in js.get("messages", []):
            msg = _parse_message(m)
            seen[msg.message_id] = msg
    return tuple(seen.values())
