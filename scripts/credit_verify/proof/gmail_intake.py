"""FILE ONLY: documents customers emailed to support@muso.ai, into proof_intake (proof-loop lead
032, captain 01:4xZ "documents that might have been missed": 775 support@ messages from pending
users, none ever analysed).

Same contract as the Intercom filer (`intake.py`): one `proof_intake` row per (account, document),
the account's open credit requests as candidates, NO judgement (no forensics, fingerprint or
verdict row). Same rules as the E-IN Maildir reader (`email_in.py`), so email has one rule set:

  1. AUTHENTICATED SENDER ONLY: the From address counts only when Google's own receiving MTA
     (authserv-id `mx.google.com`, the first such header) stamped dmarc=pass, or dkim=pass for a
     domain aligned with From. Anything else is refused and counted, never filed.
  2. MATCHED BY ACCOUNT, never by text: that address must be the confirmed email of exactly one
     Muso account (admin GET /admin/user, exhausted; `email_in.match_account`).
  3. The attachments `email_in.attachments` accepts (png/jpeg/webp/heic/pdf, <= 25 MB, at most
     10). Oversized ones are COUNTED (`files_too_large`), never silently skipped.

Messages are read with `gog gmail get <id> --format raw` (read-only), at most one per second.
`file_path` stays NULL and `conversation_id` is `gmail:<message id>`. With `blobs` (an applied run), the
attachment's bytes are stored by sha256 at filing time (docverify/blobs.py), so the reader never re-pulls
the message (Fable 10-31: the reader's re-pulls held support@ at 429 for 9 h). Dry run unless apply=True.
"""

from __future__ import annotations

import base64
import email
import email.policy
import hashlib
import json
import subprocess
import time
from email.message import EmailMessage
from datetime import timezone
from email.utils import parsedate_to_datetime
from typing import Any, Callable

from .email_in import ACCEPTED_TYPES, MAX_ATTACHMENT_BYTES, attachments, authenticated_sender, match_account, \
    user_hash
from .store import ProofStore

ACCOUNT = "support@muso.ai"
AUTHSERV = "mx.google.com"
PREFIX = "gmail:"

RawFetch = Callable[[str], bytes]                          # message id -> RFC 822 bytes
Lookup = Callable[[str], list[dict[str, Any]]]             # email_in.admin_user_lookup(admin)
OpenRows = Callable[[list[int]], dict[int, list[dict[str, Any]]]]


def gog_raw(message_id: str, *, account: str = ACCOUNT, min_interval: float = 1.0,
            _last: list[float] = [0.0]) -> bytes:  # noqa: B006 - the pacing clock, shared on purpose
    """One message as RFC 822 bytes through gog (read-only `get --format raw`), paced."""
    if not message_id or not all(c.isalnum() for c in message_id):
        raise ValueError("not a Gmail message id")
    wait = min_interval - (time.monotonic() - _last[0])
    if wait > 0:
        time.sleep(wait)
    _last[0] = time.monotonic()
    p = subprocess.run(["gog", "gmail", "get", message_id, "--account", account, "--format", "raw", "--json",
                        "--no-input"], capture_output=True, text=True, timeout=120, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"gog rc={p.returncode}: {p.stderr.strip()[-200:]}")
    d = json.loads(p.stdout)
    raw = (d.get("message") or d).get("raw") or ""
    return base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))


def read_message_ids(path: str) -> tuple[list[str], list[str]]:
    """(ids, rejected) from a list file: Gmail message ids are hex, one per line or whitespace
    separated, `#` comments allowed. A token that is not a message id is RETURNED, never
    silently dropped (the Intercom list reader keeps digits only)."""
    ids: list[str] = []
    bad: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            for t in line.split("#", 1)[0].split():
                if t.isascii() and t.isalnum() and len(t) <= 32:
                    if t not in ids:
                        ids.append(t)
                else:
                    bad.append(t[:40])
    return ids, bad


def parse(raw: bytes) -> EmailMessage:
    return email.message_from_bytes(raw, policy=email.policy.default)  # type: ignore[return-value]


def oversized(msg: EmailMessage) -> int:
    """Attachments email_in would accept by type but that exceed the size cap."""
    n = 0
    for part in msg.walk():
        if part.is_multipart() or part.get_content_type().lower() not in ACCEPTED_TYPES:
            continue
        if (part.get_content_disposition() or "").lower() == "attachment" \
                and len(part.get_payload(decode=True) or b"") > MAX_ATTACHMENT_BYTES:
            n += 1
    return n


def received_at(msg: EmailMessage) -> str:
    try:
        return parsedate_to_datetime(str(msg.get("Date"))).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") \
            if msg.get("Date") else ""
    except (TypeError, ValueError):
        return ""


def message_attachment(raw: bytes, sha: str) -> tuple[str, str, bytes] | None:
    """The attachment of a message whose bytes hash to `sha` (the reader's locator)."""
    for name, ctype, data in attachments(parse(raw)):
        if hashlib.sha256(data).hexdigest() == sha:
            return name, ctype, data
    return None


def run(store: ProofStore, *, message_ids: list[str], fetch: RawFetch, lookup: Lookup, open_rows: OpenRows,
        apply: bool = False, authserv: str = AUTHSERV, filed_by: str = "credit-proof.py file --source gmail",
        log: Callable[[str], None] = lambda m: None,
        blobs: Callable[[str, bytes], Any] | None = None) -> dict[str, Any]:
    stats: dict[str, Any] = {"messages": len(message_ids), "filed_messages": [], "duplicate_messages": [],
                             "no_document_messages": [], "refused": {}, "fetch_errors": [],
                             "files_filed": 0, "files_duplicate": 0, "files_too_large": 0,
                             "candidates_refreshed": 0, "users": 0, "with_candidate_requests": 0,
                             "blobs_stored": 0, "blob_errors": 0}

    def keep_bytes(sha: str, data: bytes) -> None:
        # The bytes we already hold, stored once by sha256; a failure never blocks the filing (the bytes are
        # then restored by the paced blob-backfill, never by the reader).
        if not (apply and blobs is not None):
            return
        try:
            blobs(sha, data)
            stats["blobs_stored"] += 1
        except Exception as exc:  # noqa: BLE001 - counted and logged
            stats["blob_errors"] += 1
            log(f"blob {sha[:12]}: {type(exc).__name__}")
    matched: list[tuple[str, EmailMessage, int, str]] = []
    for mid in dict.fromkeys(str(m).strip() for m in message_ids if str(m).strip()):
        try:
            msg = parse(fetch(mid))
        except Exception as exc:  # noqa: BLE001 - counted; the message is retried by a re-run
            stats["fetch_errors"].append(f"{mid}: {type(exc).__name__}")
            continue
        sender, why = authenticated_sender(msg, authserv)
        if sender is None:
            stats["refused"][why] = stats["refused"].get(why, 0) + 1
            continue
        try:
            acct, why = match_account(sender, lookup)
        except Exception as exc:  # noqa: BLE001 - an admin failure files nothing for this message
            stats["fetch_errors"].append(f"{mid}: account lookup {type(exc).__name__}")
            continue
        if acct is None or not isinstance(acct.get("id"), int):
            stats["refused"][why] = stats["refused"].get(why, 0) + 1
            continue
        matched.append((mid, msg, int(acct["id"]), why))
    rows = open_rows(sorted({u for _m, _g, u, _w in matched})) if matched else {}
    users: set[int] = set()
    seen: set[tuple[int, str]] = set()     # (account, sha256) counted this run: a dry run writes nothing,
    for mid, msg, uid, how in matched:      # so without this a re-sent attachment was counted twice
        users.add(uid)
        cands = [str(r["request_id"]) for r in rows.get(uid, [])]
        stats["files_too_large"] += oversized(msg)
        files = attachments(msg)
        if not files:
            stats["no_document_messages"].append(mid)
            continue
        filed_here = 0
        for name, ctype, data in files:
            sha = hashlib.sha256(data).hexdigest()
            if (uid, sha) in seen:
                stats["files_duplicate"] += 1
                continue
            seen.add((uid, sha))
            if store.already_filed(uid, sha):
                keep_bytes(sha, data)
                if (store.add_candidates(uid, sha, cands) if apply else store.missing_candidates(uid, sha, cands)):
                    stats["candidates_refreshed"] += 1
                stats["files_duplicate"] += 1
                continue
            if apply:
                store.file_document(file_sha256=sha, user_id=uid, conversation_id=PREFIX + mid, subject="credit",
                                    candidate_request_ids=cands, source="email", file_path=None,
                                    received_at=received_at(msg), filed_by=filed_by,
                                    matched_by="authenticated_email", contact_h=user_hash(uid), mime=ctype,
                                    nbytes=len(data), detail={"provenance": PREFIX + mid, "name": name[-80:],
                                                              "sender_auth": how})
                keep_bytes(sha, data)
            stats["files_filed"] += 1
            filed_here += 1
        stats["filed_messages" if filed_here else "duplicate_messages"].append(mid)
        log(f"{mid}: user …{str(uid)[-4:]}, {len(files)} file(s), {len(cands)} candidate request(s), {filed_here} filed")
    stats["users"] = len(users)
    stats["with_candidate_requests"] = sum(1 for u in users if rows.get(u))
    return stats
