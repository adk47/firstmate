"""The shared support@ Gmail lock, for callers that are not go_raw.

`gmail_intake.gog_raw` takes `/run/hydra/gmail-support.lock` per fetch, and `cs_proof_feed/gmail_scan.sh`
holds it for a whole scan. The SEARCH path (`recent.gog_search`) was the one support@ request that took no
lock: the hourly file-recent intake pages through searches before it ever calls gog_raw, so it could run
alongside the proof scan (QA on #1558). Everything that speaks to support@'s Gmail now goes through here or
through gog_raw.

Fail closed: a lock that cannot be taken is a refusal, never an unlocked request.
"""

from __future__ import annotations

from contextvars import ContextVar
from typing import Callable, TypeVar

T = TypeVar("T")

# [key=check-the-backoff-again-under-the-lock] (QA #1567 finding 1): a caller whose callable takes the shared lock
# itself cannot be guarded from outside it - its wait for the lock is inside `call`. So the guard REGISTERS the
# recheck here and the lock holder runs it the moment the lock is ours, before `call` issues anything.
AFTER_LOCK: ContextVar[Callable[[], None] | None] = ContextVar("support_gmail_after_lock", default=None)

LOCK_PATH = "/run/hydra/gmail-support.lock"
LOCK_FALLBACK_DIR = "/var/lib/hydra/cs-proof-feed/gmail"


def hold_support_gmail_lock(call: Callable[[], T], wait_s: float = 60.0) -> T:
    """Run `call` while holding the shared support@ Gmail lock, then release it.

    [key=a-denied-lock-is-a-stop] (QA #1567 finding 2): a lock that cannot be taken raises the TYPED `GmailLockBusy`,
    never a bare RuntimeError - the search helper's caller (`gmail_quota.guarded`) turns exactly that type into a
    clean stop, so a busy lock ends the run and holds the window instead of aborting one search and letting the
    fetch go on message by message."""
    from .gmail_intake import GmailLockBusy, _support_gmail_lock  # one statement of the path and the fallback

    lock = _support_gmail_lock(wait_s=wait_s)
    if lock is None:
        raise GmailLockBusy("cannot take the support@ Gmail lock: refusing to search unlocked")
    try:
        after = AFTER_LOCK.get()
        if after is not None:
            after()          # inside the lock: a window recorded while we waited is seen before any request
        return call()
    finally:
        lock.close()
