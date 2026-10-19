"""E-IN: the email channel for verification documents (captain's first
principle, 2026-10-15: proof arrives by EMAIL or Intercom, matched by account,
fraud-checked before it counts).

Transport (H-DevOps, separate change): mail to the dedicated address (e.g.
verify@muso.ai) is delivered as raw RFC 822 files into a Maildir on node-8,
`$CREDIT_PROOF_EMAIL_MAILDIR/new/`. This module only reads that Maildir:

  1. AUTHENTICATED SENDER ONLY. The From address counts only when the
     receiving MTA we trust (CREDIT_PROOF_EMAIL_AUTHSERV, default
     mx.cloudflare.net) stamped `Authentication-Results` with dmarc=pass, or
     dkim=pass for a d= domain aligned with the From domain. Anything else is
     treated as spoofable: nothing is attached, the message is filed under
     `rejected/` with the reason.
  2. MATCHED BY ACCOUNT, never by text: the authenticated From address must be
     the email of exactly one Muso user whose email is confirmed
     (emailConfirmed is true) - GET /admin/user?keyword=<address>, read page by
     page until exhausted, exact case-insensitive match. The subject and body
     are never used to pick the account or the credit. An admin API failure or
     an unexpected response leaves the message in new/ for the next run.
  3. Every attachment (png/jpeg/webp/heic/pdf) goes through the same sandboxed
     forensics as an Intercom file, with source='email' and the submitter hash
     "user:<id>", so reuse matching works across both channels.
Processed messages move to `cur/`; nothing is deleted. A message with an
attachment that came out UNDETERMINED stays in `new/` and is analysed again
(already-final attachments are skipped) until store.MAX_ATTEMPTS. Nothing is
sent from here (the acknowledgement reply belongs to the messaging lane).
"""

from __future__ import annotations

import email
import email.policy
import hashlib
import os
import re
import shutil
import tempfile
from dataclasses import dataclass, field
from email.message import EmailMessage
from email.utils import getaddresses
from typing import Any, Callable

from credit_review.admin import AdminError

from .fingerprint import sha256
from .pipeline import Runner, extract, finalize
from .signals import ClaimContext
from .store import ProofStore
from . import sandbox

MAILDIR = os.environ.get("CREDIT_PROOF_EMAIL_MAILDIR", "/var/lib/hydra-credit-verify/inbound-email")
AUTHSERV = os.environ.get("CREDIT_PROOF_EMAIL_AUTHSERV", "mx.cloudflare.net")
ACCEPTED_TYPES = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/heic": ".heic",
                  "image/heif": ".heic", "application/pdf": ".pdf", "application/octet-stream": ""}
MAX_ATTACHMENTS = 10
MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
LOOKUP_PAGE_SIZE = 100
LOOKUP_MAX_PAGES = 5


def user_hash(user_id: Any) -> str:
    """Same submitter key the app channel will use, so reuse matching sees
    one user across channels. (Intercom files carry the Intercom contact hash
    until core C1b maps contacts to users.)"""
    return hashlib.sha256(f"muso-user:{user_id}".encode()).hexdigest()[:16]


def _domain(addr: str) -> str:
    return addr.rsplit("@", 1)[-1].lower().strip(".") if "@" in addr else ""


def _aligned(d: str, from_domain: str) -> bool:
    d = d.lower().strip(".")
    return bool(d) and (from_domain == d or from_domain.endswith("." + d) or d.endswith("." + from_domain))


def authenticated_sender(msg: EmailMessage, authserv: str = AUTHSERV) -> tuple[str | None, str]:
    """(address, why). Only Authentication-Results headers whose authserv-id
    (the first token before ';') is exactly the receiving MTA we trust are
    read; earlier hops can be forged, and so can a look-alike id such as
    'mx.cloudflare.net.attacker'. The first such header (the topmost, stamped
    last by our MTA) decides."""
    froms = [a for _n, a in getaddresses(msg.get_all("From", [])) if a]
    if len(froms) != 1:
        return None, "missing_or_multiple_from"
    sender = froms[0].strip().lower()
    fdom = _domain(sender)
    for hdr in msg.get_all("Authentication-Results", []):
        text = " ".join(str(hdr).split())
        head = text.split(";", 1)[0].split()
        if not head or head[0].lower() != authserv.lower():
            continue
        if re.search(r"\bdmarc=pass\b", text, re.I):
            return sender, "dmarc=pass"
        for m in re.finditer(r"\bdkim=pass\b[^;]*?header\.d=([A-Za-z0-9.\-]+)", text, re.I):
            if _aligned(m.group(1), fdom):
                return sender, "dkim=pass aligned"
        return None, "authentication_failed"
    return None, "no_trusted_authentication_results"


Lookup = Callable[[str], list[dict[str, Any]]]


def admin_user_lookup(admin) -> Lookup:
    """Every user row the keyword search returns for the address. Raises
    AdminError on an unexpected response or when the search runs past
    LOOKUP_MAX_PAGES (it could hide a second account with this email)."""
    def look(address: str) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for page in range(1, LOOKUP_MAX_PAGES + 1):
            data = admin.get("/admin/user", {"keyword": address, "limit": LOOKUP_PAGE_SIZE, "page": page})
            items = data.get("items") if isinstance(data, dict) else None
            if not isinstance(items, list) or not all(isinstance(r, dict) for r in items):
                raise AdminError("/admin/user returned no items[] of objects")
            rows += items
            if len(items) < LOOKUP_PAGE_SIZE:
                return rows
        raise AdminError(f"/admin/user search not exhausted after {LOOKUP_MAX_PAGES} pages")
    return look


def match_account(address: str, lookup: Lookup) -> tuple[dict[str, Any] | None, str]:
    rows = [r for r in lookup(address) if str(r.get("email") or "").strip().lower() == address]
    if not rows:
        return None, "no_account_with_this_email"
    if len(rows) > 1:
        return None, "several_accounts_with_this_email"
    if rows[0].get("emailConfirmed") is not True:
        return None, "account_email_not_confirmed"
    return rows[0], "matched"


def attachments(msg: EmailMessage) -> list[tuple[str, str, bytes]]:
    out = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        disp = (part.get_content_disposition() or "").lower()
        ctype = part.get_content_type().lower()
        if disp not in ("attachment", "inline") or ctype not in ACCEPTED_TYPES:
            continue
        if disp == "inline" and not part.get_filename():
            continue          # signature logos and tracking pixels
        payload = part.get_payload(decode=True) or b""
        if not payload or len(payload) > MAX_ATTACHMENT_BYTES:
            continue
        out.append((part.get_filename() or "attachment", ctype, payload))
        if len(out) >= MAX_ATTACHMENTS:
            break
    return out


@dataclass
class EmailRunStats:
    messages: int = 0
    accepted: int = 0
    retry: int = 0
    rejected: dict[str, int] = field(default_factory=dict)
    files: int = 0
    verdicts: dict[str, int] = field(default_factory=dict)


def _file_into(maildir: str, sub: str, name: str, note: str | None = None) -> None:
    os.makedirs(os.path.join(maildir, sub), mode=0o700, exist_ok=True)
    shutil.move(os.path.join(maildir, "new", name), os.path.join(maildir, sub, name))
    if note:
        with open(os.path.join(maildir, sub, name + ".reason"), "w", encoding="utf-8") as fh:
            fh.write(note + "\n")


def run(store: ProofStore, lookup: Lookup, *, maildir: str = MAILDIR, runner: Runner = sandbox.run,
        authserv: str = AUTHSERV, max_messages: int = 200) -> EmailRunStats:
    stats = EmailRunStats()
    new = os.path.join(maildir, "new")
    if not os.path.isdir(new):
        return stats
    for name in sorted(os.listdir(new))[:max_messages]:
        path = os.path.join(new, name)
        if not os.path.isfile(path):
            continue
        stats.messages += 1
        with open(path, "rb") as fh:
            msg = email.message_from_binary_file(fh, policy=email.policy.default)
        sender, why = authenticated_sender(msg, authserv)
        account = None
        if sender:
            try:
                account, why = match_account(sender, lookup)
            except AdminError:
                stats.retry += 1
                continue
        if account is None:
            stats.rejected[why] = stats.rejected.get(why, 0) + 1
            _file_into(maildir, "rejected", name, why)
            continue
        stats.accepted += 1
        contact = user_hash(account.get("id"))
        msg_id = hashlib.sha256(str(msg.get("Message-ID") or name).encode()).hexdigest()[:16]
        pending = False
        with tempfile.TemporaryDirectory(prefix="cvmail-") as tmp:
            for i, (fname, ctype, data) in enumerate(attachments(msg)):
                if store.analyzed(sha256(data), contact, None):
                    continue
                ext = ACCEPTED_TYPES.get(ctype) or os.path.splitext(fname)[1].lower()[:6]
                fpath = os.path.join(tmp, f"{i}{ext}")
                with open(fpath, "wb") as fh:
                    fh.write(data)
                raw = extract(fpath, ctype if ctype != "application/octet-stream" else None, ClaimContext(), runner)
                [res] = finalize(store, fpath, raw, contact_h=contact, source="email",
                                 source_ref=f"email:{msg_id}/{i}", ctx=ClaimContext())
                stats.files += 1
                stats.verdicts[res.verdict] = stats.verdicts.get(res.verdict, 0) + 1
                pending = pending or not store.analyzed(res.proof_id, contact, None)
        if pending:
            stats.retry += 1
            continue
        _file_into(maildir, "cur", name)
    return stats
