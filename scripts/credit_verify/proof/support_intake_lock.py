"""The shared support@ Gmail lock, for callers that are not go_raw.

`gmail_intake.gog_raw` takes `/run/hydra/gmail-support.lock` per fetch, and `cs_proof_feed/gmail_scan.sh`
holds it for a whole scan. The SEARCH path (`recent.gog_search`) was the one support@ request that took no
lock: the hourly file-recent intake pages through searches before it ever calls gog_raw, so it could run
alongside the proof scan (QA on #1558). Everything that speaks to support@'s Gmail now goes through here or
through gog_raw.

Fail closed: a lock that cannot be taken is a refusal, never an unlocked request.
"""

from __future__ import annotations

from typing import Callable, TypeVar

T = TypeVar("T")

LOCK_PATH = "/run/hydra/gmail-support.lock"
LOCK_FALLBACK_DIR = "/var/lib/hydra/cs-proof-feed/gmail"


def hold_support_gmail_lock(call: Callable[[], T], wait_s: float = 60.0) -> T:
    """Run `call` while holding the shared support@ Gmail lock, then release it."""
    from .gmail_intake import _support_gmail_lock  # one statement of the path and the fallback

    lock = _support_gmail_lock(wait_s=wait_s)
    if lock is None:
        raise RuntimeError("cannot take the support@ Gmail lock: refusing to search unlocked")
    try:
        return call()
    finally:
        lock.close()
