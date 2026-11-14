"""notify-tick: the class `precedent_v1_untold` and who in it has not been told yet.

Ported from two files that were host-only on node-8: `/opt/hydra/scripts/credit-notify-tick.py` (the tick, whose
port is now `scripts/credit-notify-tick.py`) and `/root/mklist2.js` (the class query it copied into a core-backend pod
and ran there, still host-only). This module is the part of the tick that decides WHO: the class, the list built from
it, and the subtraction of users this path already tried. It sends nothing and writes nothing; the per-user
eligibility and the send stay in `decision_told.py` (one notice per (workspace, profile) group, the 7-day slot, the
signed dry run, the day cap).

The class, in words: a credit request that is not deleted, has a user, was approved through the precedent rule
(`metadata.approval.via = 'precedent_v1'`) and carries neither core notice stamp
(`metadata.approvedNotice.noticeSentAt`, `metadata.decisionNotice.noticeSentAt`).

**The class is defined by the approval ROUTE and the absence of a notice stamp, not by the request's current status**
- exactly as the host query had it. A request whose status has since moved (a reversal, a re-open, or the bulk writer
that flipped 9,465 precedent rows to `approved` on 2026-11-10) stays in the class and in `untold_users`,
`untold_requests` and `untold_paid_users`. Those counts are the MOST the sender could tell, never a promise:
`decision_told.plan` re-reads every request and holds or drops per user (`moved`, `mixed_decisions`,
`not_a_decision`).

OPEN ITEM, to close before any sender is wired to this list: a user whose class requests are all `rejected` today
would be planned by `decision_told` under `decision-rejected`, so a tick meant to tell people about approved credits
could send a rejection. Either the class takes `cr.status = 'approved'` - with the mixed-decision ruling decided at
the same time, because a status filter in the list would hand a user with an approved and a rejected request over
with the approved requests only, lifting a hold that belongs to `decision_told` - or the sender refuses any copy
other than `decision-approved`. This change sends nothing, so nothing reaches that path today.

**The class is not the untold population.** A user whose live attempt errored or never completed carries no stamp,
and whether a completed send writes `decisionNotice.noticeSentAt` is core's behaviour and is not verified by this
change. So who is still untold is the class MINUS the users `decision_told` holds a live (`mode = 'apply'`) row for;
`select()` does that and records both counts, so the header can no longer be read as "this many people are waiting".
The numbers measured on node-8 2026-11-13T20:18Z - 1,177 users / 10,259 requests in the class, 1,174 of those users
with a live row (1,126 `sent`, 44 `error`, 4 `attempt` only), 3 left - are the HOST's class under the host's
predicate. The size of the class under this module's statement is NOT MEASURED: two timed probes against the replica
were killed at 160 s and 286 s without finishing, against about 40-60 s for the host's read on Postgres, so the
statement's own runtime must be measured before any 20-minute tick relies on it.

What differs from the host files, and why:
  - the read is the core replica through the caller's `Query` (the repo's reviewed read path), not a script copied
    into a prod pod and run on the primary with the application's own database credentials;
  - `paid` is read (see below); the host query hardcoded `paid: false` for every user, so "paid first" never
    ordered anything;
  - `query_sha` is the sha256 of the statement; on the host it was the class name written again;
  - a request with no user is left out by the statement (there is nobody to tell);
  - the never-automated users come from `decision_told.NEVER_AUTOMATED_USERS`, not a literal 15;
  - the host query tested `metadata.approval.noticeSentAt`, a path no code in this repository reads or writes, so
    that half of its class was inert; this statement tests the two stamps `decision_told.core_rows` reads.

Kept as the host had it: the subtraction is by USER and counts every live row, not only `sent` (the second host
hand-patch, 2026-11-11T02:39Z: before it, a user whose send errored was listed again on every tick). So a user whose
live attempt errored is never listed again by this path, and neither is a told user's later group.

What `paid` means here: the user has a listed class request in a workspace with an active or trialing subscription
(`fraud_lens.PAID_TEAMS`). That is the credit-review lists' own definition - `owing_proof.REPLICA_SQL`,
`fraud_lens.paid_never_contacted` and `verification-queue-report.py` all read paid from the request's workspace - so
`untold_paid_users` is comparable with their paid counts. It is NOT team membership: `scripts/intercom-backlog/triage.py`
reads paid from `team_users` because its population includes subscribers with no credit request, and every user here
has one. The known miss, stated rather than hidden: a subscriber whose class requests all sit in an unpaid workspace
is listed as unpaid. `paid` only orders the list; it never decides whether a user is listed, so that user is still
told, later in the order. Changing the scope to membership is a definition change: it edits `CLASS_SQL` and therefore
`CLASS_SHA`, in one deliberate commit.

Why the notice-stamp half of the class is safe: `decision_told.plan` already drops a request carrying either stamp
as `core_notice_recorded`, so the statement leaves out only requests the sender would have dropped. It cannot remove
anyone who would have been told; it makes the class and its counts agree with what the sender does.
"""
from __future__ import annotations

import hashlib
import sqlite3
from datetime import datetime
from typing import Any, Callable

from . import decision_told as dt
from .fraud_lens import PAID_TEAMS

CLASS = "precedent_v1_untold"
USER_CLASS = "precedent_v1"
RULING = "captain 2026-11-10 no humans"
SOURCE = "credit_requests"

#: The class, as one read-only statement against the core replica. One row per request:
#: user id, request id, status, updatedat, whether the request's workspace is paid.
CLASS_SQL = (
    "SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), cr.status, CAST(cr.updatedat AS varchar), "
    f"CAST(CASE WHEN cr.workspaceid IN {PAID_TEAMS} THEN 1 ELSE 0 END AS varchar) "
    "FROM postgresql_core.public.credit_requests cr "
    "WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL "
    "AND json_extract_scalar(cr.metadata, '$.approval.via') = 'precedent_v1' "
    "AND json_extract_scalar(cr.metadata, '$.approvedNotice.noticeSentAt') IS NULL "
    "AND json_extract_scalar(cr.metadata, '$.decisionNotice.noticeSentAt') IS NULL "
    "ORDER BY cr.userid, cr.id"
)

#: Users this path already tried: every live row, whatever its outcome (see the module docstring).
TOLD_SQL = "SELECT DISTINCT user_id FROM decision_told WHERE mode = 'apply'"

Query = Callable[[str], "list[list[str]]"]


class NotifyTickError(RuntimeError):
    """The class or the ledger could not be read. Never an empty list: an unread class is not an empty class."""


def query_sha() -> str:
    return hashlib.sha256(CLASS_SQL.encode()).hexdigest()[:12]


def build_list(query: Query, now: datetime) -> dict[str, Any]:
    """The whole class as the list `decision_told.load_list` reads when it names a user: {class, counts,
    generated_at, query_sha, ruling, source, users: [{user_id, paid, class, facts: [[request id, status,
    updatedat]]}]}, users by id. An empty `users` is a MEASURED zero - the class was read and nobody is in it - so the
    caller stops there; it is never handed to `load_list`, which refuses an empty list. A row that is not the expected
    shape refuses the build; a user is paid when any listed request sits in a paid workspace - the request's own
    workspace, not team membership (see the module docstring), which only orders the list."""
    by_user: dict[int, dict[str, Any]] = {}
    requests = 0
    for row in query(CLASS_SQL):
        if len(row) != 5:
            raise NotifyTickError(f"class row has {len(row)} columns, want 5")
        uid, rid, status, updated, paid = (str(x) for x in row)
        if not uid.isdigit() or len(rid) != 36 or not set(rid) <= dt.UUID_CHARS or not status or paid not in ("0", "1"):
            raise NotifyTickError("class row unreadable")
        user = by_user.setdefault(int(uid), {"user_id": int(uid), "paid": False, "class": USER_CLASS, "facts": []})
        user["paid"] = user["paid"] or paid == "1"
        user["facts"].append([rid, status, updated])
        requests += 1
    users = [by_user[k] for k in sorted(by_user)]
    for user in users:
        user["facts"].sort()
    return {"class": CLASS, "counts": {"users": len(users), "requests": requests},
            "generated_at": now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z",
            "query_sha": query_sha(), "ruling": RULING, "source": SOURCE, "users": users}


def already_told(db: sqlite3.Connection) -> set[int]:
    """Every user with a live row in `decision_told`. A ledger that cannot answer raises: read as "nobody was told",
    it would list every told user again."""
    try:
        return {int(r[0]) for r in db.execute(TOLD_SQL)}
    except (sqlite3.Error, TypeError, ValueError) as exc:
        raise NotifyTickError(f"decision_told unreadable: {type(exc).__name__}: {exc}") from exc


def select(doc: dict[str, Any], told: set[int]) -> dict[str, Any]:
    """The list with the told and the never-automated users taken out, paid users first, then by user id.

    A never-automated user in the class is SKIPPED and counted, never a refusal: the class is a predicate over
    credit_requests, so one account's data must not stop the tick for every other user. `already_tried_users` counts
    only the class users who are not in `dt.NEVER_AUTOMATED_USERS`, and `never_automated_users` counts the rest of
    them, so a user who is both keeps exactly one name and the header always closes:
    `counts["users"] == untold_users + already_tried_users + never_automated_users`.

    That identity is all the counts close on: the class is not status-filtered (see the module docstring), so
    `untold_users` and `untold_requests` are the most a sender could tell, and `decision_told.plan` holds or drops per
    user afterwards.

    The result is the list `decision_told.load_list` reads WHEN IT NAMES A USER. An empty `users` means nothing is
    left to send - the caller stops there and never hands it to `load_list`, which refuses an empty list.
    """
    users = [u for u in doc["users"]
             if int(u["user_id"]) not in told and int(u["user_id"]) not in dt.NEVER_AUTOMATED_USERS]
    users.sort(key=lambda u: (u.get("paid") is not True, int(u["user_id"])))
    never = {int(u["user_id"]) for u in doc["users"]} & dt.NEVER_AUTOMATED_USERS
    counts = dict(doc["counts"])
    counts["untold_users"] = len(users)
    counts["untold_requests"] = sum(len(u["facts"]) for u in users)
    counts["untold_paid_users"] = sum(u.get("paid") is True for u in users)
    counts["never_automated_users"] = sum(int(u["user_id"]) in never for u in doc["users"])
    counts["already_tried_users"] = sum(int(u["user_id"]) in told and int(u["user_id"]) not in never
                                        for u in doc["users"])
    return {**doc, "counts": counts, "users": users}
