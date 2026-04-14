"""Gog-CLI adapter for Gmail operations.

Parses the raw Gmail-API-shaped JSON that `gog gmail ... --json` emits:

- `drafts get` returns `{"draft": {"id", "message": {...}}}`
- `threads get` returns `{"thread": {"id", "messages": [...]}}`
- `drafts send` returns `{"draftId", "message": {"id": ...}, "threadId"}`
- `drafts list` returns `{"drafts": [{"id": ...}, ...]}`
- `messages search` returns a simplified `{"messages": [{"id", "from", ...}]}`
  (no `payload`, no `to`, no `internalDate`)

Each `message.payload.headers` is a list of `{"name", "value"}` dicts where
the values are RFC-5322 strings like `"Ole <ow@larsenstrings.com>"`.
`labelIds` on messages contains Gmail-internal IDs (`Label_…` for user
labels, uppercase for system labels); we resolve them to human-readable
names via a per-process cache fetched once on first use.
"""
from __future__ import annotations

import base64
import json
import re
from typing import Optional

from ._gog import run_gog
from .types import Draft, Message, Thread

# Module-level cache: {account: {label_id: label_name}}
_LABEL_CACHE: dict[str, dict[str, str]] = {}

_ADDR_RE = re.compile(r"<([^>]+)>")


def _label_map(account: str) -> dict[str, str]:
    """Resolve label id → human-readable name for the given account.

    Cached per-process.
    """
    if account not in _LABEL_CACHE:
        out = run_gog("gmail", "labels", "list", "--account", account, "--json")
        js = json.loads(out)
        _LABEL_CACHE[account] = {
            l["id"]: l.get("name", l["id"]) for l in js.get("labels", [])
        }
    return _LABEL_CACHE[account]


def _header(headers: list[dict], name: str) -> Optional[str]:
    """Case-insensitive header lookup in a payload.headers list."""
    lname = name.lower()
    for h in headers or []:
        if h.get("name", "").lower() == lname:
            return h.get("value")
    return None


def _parse_email(raw: Optional[str]) -> Optional[str]:
    """Extract a bare email from RFC-5322 forms.

    Accepts: `"Name <email@x>"`, `"<email@x>"`, `"email@x"`, or None.
    Returns the lowercase trimmed email, or None if unparseable.
    """
    if not raw:
        return None
    m = _ADDR_RE.search(raw)
    email = (m.group(1) if m else raw).strip().strip('"').strip("'").lower()
    return email or None


def _parse_address_list(raw: Optional[str]) -> tuple[str, ...]:
    """Parse an RFC-5322 address-list header into bare lowercase emails."""
    if not raw:
        return ()
    out: list[str] = []
    # Comma-split is imperfect for quoted names containing commas, but
    # outreach uses simple "Name <email>" forms. Any parsing failure
    # here results in Gate A blocking fail-safe.
    for part in raw.split(","):
        email = _parse_email(part)
        if email:
            out.append(email)
    return tuple(out)


def _b64url_decode(data: str) -> str:
    """Gmail uses URL-safe base64 with padding stripped."""
    padding = "=" * (-len(data) % 4)
    try:
        return base64.urlsafe_b64decode(data + padding).decode("utf-8", errors="replace")
    except Exception:
        return ""


def _decode_body_html(payload: Optional[dict]) -> str:
    """Walk a payload tree and return the HTML body (or plain-text body
    if no HTML part exists), base64-decoded.
    """
    if not payload:
        return ""
    mime = payload.get("mimeType", "")
    body = payload.get("body") or {}
    data = body.get("data")
    if data and mime == "text/html":
        return _b64url_decode(data)

    # Recurse into parts, preferring text/html.
    parts = payload.get("parts") or []
    html = ""
    plain = ""
    for part in parts:
        result = _decode_body_html(part)
        if part.get("mimeType") == "text/html" and result:
            html = result
            break
        if part.get("mimeType") == "text/plain" and not plain:
            plain = result

    if html:
        return html
    if data and mime == "text/plain":
        return _b64url_decode(data)
    return plain


def _message_from_payload(msg: dict) -> Message:
    """Build a Message from the raw Gmail API shape."""
    headers = (msg.get("payload") or {}).get("headers") or []
    internal = msg.get("internalDate") or "0"
    try:
        epoch_ms = int(internal)
    except ValueError:
        epoch_ms = 0
    return Message(
        message_id=msg.get("id", ""),
        thread_id=msg.get("threadId", ""),
        from_addr=_parse_email(_header(headers, "From")) or "",
        to_addrs=_parse_address_list(_header(headers, "To")),
        cc_addrs=_parse_address_list(_header(headers, "Cc")),
        bcc_addrs=_parse_address_list(_header(headers, "Bcc")),
        date_epoch=epoch_ms // 1000,
    )


def _resolve_labels(label_ids: list[str], label_map: dict[str, str]) -> tuple[str, ...]:
    """Map Gmail label IDs → human-readable names; pass system labels
    (already uppercase strings) through unchanged."""
    return tuple(label_map.get(lid, lid) for lid in label_ids or ())


def fetch_draft(draft_id: str, account: str) -> Draft:
    out = run_gog("gmail", "drafts", "get", draft_id,
                  "--account", account, "--json")
    js = json.loads(out)
    d = js.get("draft") or {}
    msg = d.get("message") or {}
    headers = (msg.get("payload") or {}).get("headers") or []
    label_ids = msg.get("labelIds") or []
    labels = _resolve_labels(label_ids, _label_map(account))
    return Draft(
        draft_id=d.get("id", ""),
        account=account,
        to_addrs=_parse_address_list(_header(headers, "To")),
        cc_addrs=_parse_address_list(_header(headers, "Cc")),
        bcc_addrs=_parse_address_list(_header(headers, "Bcc")),
        body_html=_decode_body_html(msg.get("payload")),
        labels=labels,
        reply_to_message_id=_header(headers, "In-Reply-To"),
    )


def fetch_thread(thread_id: str, account: str) -> Thread:
    out = run_gog("gmail", "threads", "get", thread_id,
                  "--account", account, "--json")
    js = json.loads(out)
    t = js.get("thread") or {}
    # Touch the label cache so callers can resolve draft labels later
    # (and to warm it cheaply alongside the thread read).
    _label_map(account)
    msgs = tuple(_message_from_payload(m) for m in t.get("messages") or [])
    return Thread(thread_id=t.get("id", thread_id), messages=msgs)


def list_drafts_with_label(label: str, account: str) -> list[str]:
    """List drafts carrying `label`.

    gog's `drafts list` doesn't support filter flags (verified against
    gog v0.12.0 on 2026-04-14), and Gmail's search scope excludes drafts,
    so we list all drafts and filter client-side by fetching each and
    checking its labels. O(N+1) gog calls per batch — fine at current
    batch sizes (≤50 drafts/week).
    """
    out = run_gog("gmail", "drafts", "list", "--all",
                  "--account", account, "--json")
    js = json.loads(out)
    matching: list[str] = []
    for d in js.get("drafts") or []:
        did = d.get("id")
        if not did:
            continue
        try:
            draft = fetch_draft(did, account)
        except Exception:
            # Skip drafts we can't fetch (permissions, race, etc).
            continue
        if label in draft.labels:
            matching.append(did)
    return matching


def send_draft(draft_id: str, account: str) -> str:
    """Returns the message_id of the sent message."""
    out = run_gog("gmail", "drafts", "send", draft_id,
                  "--account", account, "--json")
    js = json.loads(out)
    # Shape: {"draftId": ..., "message": {"id": ..., "threadId": ...}, "threadId": ...}
    # If "message.id" is absent (unexpected gog version), return "" so the
    # caller detects an empty message_id rather than a silently-wrong draft ID.
    msg = js.get("message") or {}
    return msg.get("id") or ""


def apply_label(message_id: str, label: str, account: str) -> None:
    run_gog("gmail", "messages", "modify", message_id,
            "--add", label, "--account", account)


def search_inbound_from(email: str, days: int,
                        accounts: tuple[str, ...]) -> tuple[Message, ...]:
    """Search for messages FROM `email` in the last N days across accounts.

    `gog gmail messages search --json` returns a simplified message shape
    (no payload, no internalDate, no to/cc/bcc). Gate B only uses
    `from_addr`; other fields are defaulted to empty.
    """
    seen: dict[str, Message] = {}
    for acct in accounts:
        query = f"from:{email} newer_than:{days}d"
        out = run_gog("gmail", "messages", "search", query,
                      "--account", acct, "--json")
        js = json.loads(out)
        for m in js.get("messages") or []:
            mid = m.get("id", "")
            if mid in seen:
                continue
            seen[mid] = Message(
                message_id=mid,
                thread_id=m.get("threadId", ""),
                from_addr=_parse_email(m.get("from")) or "",
                to_addrs=(),
                cc_addrs=(),
                bcc_addrs=(),
                date_epoch=0,
            )
    return tuple(seen.values())
