"""blob-backfill: restore the bytes of support@ email filings, the ONLY path that fetches them (Fable 10-31).

The reader never calls Gmail (intake_read.locate_intake). A Gmail filing whose bytes are not stored is skipped
by the reader until this command restores them:
- **One message fetch** fills every filed attachment of that message.
- **Paced:** `min_interval` seconds between fetches, on top of gog_raw's own 1/s.
- **Budgeted:** at most `max_messages` per run.
- **Shared quota:** gog_raw takes the shared support@ Gmail lock (#1558), so this never runs alongside the
  proof-on-file scan. The CLI refuses to run on code without that lock.
- **Quota refusal** (429 / rateLimitExceeded / quota / RESOURCE_EXHAUSTED): the run stops at once and records
  `gmail_backoff_until`, from Retry-After when Google gives one, else 15 min. Every later run refuses until then.
"""

from __future__ import annotations

import hashlib
import os
import re
import sqlite3
from collections import OrderedDict
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

BACKOFF_KEY = "gmail_backoff_until"
DEFAULT_BACKOFF_S = 900
QUOTA_RE = re.compile(r"\b429\b|rateLimitExceeded|userRateLimitExceeded|quota|RESOURCE_EXHAUSTED|Too Many Requests",
                      re.I)
# Google's 429 says "Retry after <ISO8601>" (c3 #1558, measured); a plain seconds form is accepted too.
RETRY_AT_RE = re.compile(r"retry[- ]after[\"':= ]+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?", re.I)
RETRY_AFTER_RE = re.compile(r"retry[- ]after[\"':= ]+(\d{1,6})(?![\d-])", re.I)
MAX_CONSECUTIVE_ERRORS = 3


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def backoff_until(store: Any, now: datetime) -> str | None:
    """The standing Gmail backoff (ISO Z) when it is still in force, else None."""
    v = store.get_state(BACKOFF_KEY)
    return v if v and v > _iso(now) else None


def retry_after_s(message: str, now: datetime | None = None) -> int:
    """Seconds to back off: Google's 'Retry after <ISO8601>' (UTC when no offset), else 'Retry-After: <s>',
    else 15 min. A time in the past (or unparseable) never means 'retry now': at least 60 s."""
    m = RETRY_AT_RE.search(message or "")
    if m:
        try:
            tz = m.group(2) or "+00:00"
            tz = "+00:00" if tz == "Z" else (tz if ":" in tz else tz[:3] + ":" + tz[3:])
            at = datetime.fromisoformat(m.group(1) + tz)
            return max(60, int((at - (now or datetime.now(timezone.utc))).total_seconds()) + 1)
        except ValueError:
            return DEFAULT_BACKOFF_S
    m = RETRY_AFTER_RE.search(message or "")
    return max(1, int(m.group(1))) if m else DEFAULT_BACKOFF_S


def _owed(blobs: Any, sha: str) -> bool:
    """Bytes not stored, or stored but no longer hashing (QA #1563: a corrupt blob is moved aside and owed)."""
    if blobs.get(sha):
        return False
    blobs.quarantine(sha)
    return True


def owed_messages(proof_db: sqlite3.Connection, blobs: Any) -> "OrderedDict[str, set[str]]":
    """Gmail message id -> filed sha256s whose bytes are not stored (or are corrupt), oldest filing first."""
    out: OrderedDict[str, set[str]] = OrderedDict()
    for conv, sha in proof_db.execute("SELECT conversation_id, file_sha256 FROM proof_intake WHERE subject='credit' "
                                      "AND conversation_id LIKE 'gmail:%' ORDER BY received_at, intake_id"):
        if _owed(blobs, sha):
            out.setdefault(str(conv).split(":", 1)[1], set()).add(sha)
    return out


def owed_intercom(proof_db: sqlite3.Connection, store: Any, blobs: Any) -> list[Any]:
    """Intercom filings whose REGISTERED blob is gone or corrupt (rule 3: the reader never re-fetches them), oldest
    first. An Intercom filing never stored is not owed: the reader stores it on its first read."""
    from .intake_read import IntakeDoc
    out = []
    for r in proof_db.execute("SELECT intake_id, user_id, file_sha256, conversation_id, file_path, contact_h, "
                              "candidate_request_ids_json, received_at, matched_by FROM proof_intake WHERE "
                              "subject='credit' AND conversation_id NOT LIKE 'gmail:%' ORDER BY received_at, intake_id"):
        if store.blob_registered(r[2]) and _owed(blobs, r[2]):
            out.append(IntakeDoc(r[0], int(r[1]), r[2], str(r[3]), r[4], r[5] or "", [], r[7] or "", r[8] or ""))
    return out


def restore_intercom(proof_db: sqlite3.Connection, store: Any, blobs: Any, *, fetch: Callable[[str], Any] | None,
                     dl: Callable[[str, str], int] | None, cache_root: str, max_docs: int,
                     log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    """Restore registered Intercom blobs that are gone (QA #1563): the filer's cache copy first, else ONE paced
    Intercom fetch per filing (the caller's `fetch` is paced 1/s host-wide), the attachment picked by sha256."""
    import tempfile
    from .intake_read import locate_intake
    stats: dict[str, Any] = {"owed_intercom": 0, "restored": 0, "errors": []}
    owed = owed_intercom(proof_db, store, blobs)
    stats["owed_intercom"] = len(owed)
    for doc in owed[:max(0, max_docs)]:
        with tempfile.TemporaryDirectory(prefix="cvblob-") as tmp:
            os.chmod(tmp, 0o700)
            path, _ref, errs = locate_intake(doc, tmp, fetch=fetch, dl=dl, cache_root=cache_root)
            if not path:
                stats["errors"].append(f"{doc.intake_id}: {'; '.join(errs)[:120]}")
                continue
            with open(path, "rb") as fh:
                blobs.put(doc.sha, fh.read())
            store.register_blob(doc.sha, "intercom-backfill")
            stats["restored"] += 1
    return stats


def backfill(proof_db: sqlite3.Connection, store: Any, blobs: Any, *, fetch_raw: Callable[[str], bytes],
             max_messages: int, min_interval: float, now: Callable[[], datetime],
             sleep: Callable[[float], None], log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    from credit_verify.proof.gmail_intake import attachments, parse
    stats: dict[str, Any] = {"owed_messages": 0, "fetched": 0, "blobs_stored": 0, "errors": [], "stopped": None}
    standing = backoff_until(store, now())
    if standing:
        stats["stopped"] = f"gmail backoff until {standing}"
        return stats
    owed = owed_messages(proof_db, blobs)
    stats["owed_messages"] = len(owed)
    consecutive = 0
    for i, (mid, shas) in enumerate(list(owed.items())[:max(0, max_messages)]):
        if i:
            sleep(min_interval)
        try:
            raw = fetch_raw(mid)
        except Exception as exc:  # noqa: BLE001 - classified below
            msg = f"{type(exc).__name__}: {str(exc)[:300]}"
            if QUOTA_RE.search(msg):
                t = now()
                until = _iso(t + timedelta(seconds=retry_after_s(msg, t)))
                store.set_state(BACKOFF_KEY, until)
                stats["stopped"] = f"gmail quota refusal; backoff until {until}"
                log(stats["stopped"])
                return stats
            stats["errors"].append(f"{mid[-6:]}: {msg[:120]}")
            consecutive += 1
            if consecutive >= MAX_CONSECUTIVE_ERRORS:
                stats["stopped"] = f"{consecutive} consecutive Gmail errors"
                return stats
            continue
        consecutive = 0
        stats["fetched"] += 1
        for _name, _ctype, data in attachments(parse(raw)):
            sha = hashlib.sha256(data).hexdigest()
            if sha in shas:
                blobs.put(sha, data)
                store.register_blob(sha, "gmail-backfill")
                stats["blobs_stored"] += 1
    return stats
