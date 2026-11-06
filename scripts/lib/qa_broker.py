#!/usr/bin/env python3
"""qa_broker.py — the QA review broker: a durable, de-duplicating job queue.

Why this exists
===============
Before this, a QA review was launched by minting a one-shot openclaw cron job
(scripts/qa-dispatch-pr-review.sh). That launch is lossy in four ways, all
observed in production:

  * a gateway restart kills the queued one-shot before it fires, and openclaw
    never re-arms a past-due one-shot (muso-skills#2 lost 18h, core-backend#9243
    lost 15 days);
  * the dispatcher's own stale sweep then deletes the never-fired row, because
    an elapsed-time check cannot tell "queued, never ran" from "ran, still
    running";
  * nothing de-duplicates: the same commit can be dispatched twice, and a PR
    pushed five times in a minute can queue five reviews of five dead heads;
  * nothing bounds concurrency: one PR can hold two active reviews while the
    lane serializes everything behind them.

The broker is the durable record of "this exact commit needs a review" and the
single authority on "is one already running". A reviewer's only interaction
with it is claim -> work -> finish/fail. Nothing is lost on a restart, because
the queue is a row on disk, not a process in a gateway.

The key
=======
    key = <repo>#<pr>@<head_sha>       e.g. Muso-AI/hydra#1730@a1b2c3d...

The key is the unit of "has this exact commit been reviewed". It is NOT the PR:
a PR legitimately carries several heads over its life and each head needs its
own verdict. Two dispatches of the same key are always one review.

The invariants this file enforces (each has a test in scripts/tests/qa-broker.bats)
==========================================================================
  1. DEDUPE. A key that is queued, running or done is never accepted twice.
     enqueue returns status="duplicate" and rc 76 (EX_DEDUP_REFUSED, the same
     rc the dispatcher already uses for its own in-flight refusal), so callers
     that treat 76 as "no-op, do not charge an attempt" keep working.
     A key whose last review reached a failing verdict may be re-reviewed with
     --force, capped by QA_BROKER_MAX_REVIEWS_PER_KEY (default 2), because
     qa-tier-recheck legitimately re-reviews the same head after a tier label
     fix. A GO is terminal and --force cannot override it unless
     QA_BROKER_DEDUPE_DONE=off.
  2. SUPERSEDE. A newer head for the same PR cancels every older QUEUED row
     (status="superseded"); those heads are never reviewed. A newer head never
     kills a RUNNING review: its verdict is still true for the commit it
     reviewed, so it finishes, and the newer key is claimed next.
  3. ONE ACTIVE REVIEW PER PR. A partial unique index
     `one_active_review_per_pr ON jobs(repo,pr) WHERE status='running'` makes
     the invariant a database constraint, not a convention. Two concurrent
     claims race in BEGIN IMMEDIATE and exactly one wins.
  4. LEASE. A claim sets lease_until = now + lease. A crashed reviewer leaves
     its row 'running' until reap() sees the expired lease and returns it to
     'queued' (attempts preserved, a 120s not_before so it does not immediately
     re-race the same crash). The PR therefore never accumulates two active
     reviews, and never loses one either.
  5. NO SILENT DROP. Exhausted retries become status='dead' with last_error and
     an events row. reap() and stats() surface dead rows; the digest pages on
     dead > 0. A row is never deleted by this module.

Retry classes
=============
The dispatcher already distinguishes "never reached the gateway" (rc 75) from
"the gateway rejected it" (any other rc), and the reconciler counts only the
latter as an attempt. The broker keeps two independent budgets so a flapping
gateway cannot exhaust the budget that a genuine review failure needs:

  transport  -> the request never reached a reviewer. Backoff
                min(30m, 120s * 2**(n-1)), up to QA_BROKER_MAX_TRANSPORT_ATTEMPTS
                (12, ~4h). Signature list: scripts/lib/qa-dispatch-signatures.sh.
  quota      -> provider 429 / usage cap. 30m flat, up to 4.
  review     -> the reviewer ran and the turn errored. Backoff
                min(10m, 60s * 2**(n-1)), up to 3.
  lease      -> an expired lease counts as a review attempt (the reviewer
                started and died), so a crash loop cannot spin forever.

Storage
=======
One SQLite database (stdlib sqlite3, WAL, busy_timeout). Default path
/var/lib/hydra-qa/queue.sqlite, override QA_QUEUE_DB. NOT under /opt/hydra:
the deploy rsync overwrites that tree. NOT in the gateway process: a queue that
lives in the process it protects is not a durable queue.

Every mutation runs inside BEGIN IMMEDIATE so a concurrent worker cannot
interleave a read and a write. Reads use a plain connection.

CLI (called by the dispatcher and the worker)
=============================================
  enqueue <repo> <pr> <sha> <uid> [--force] [--not-before S]
          [--current-head] [--head-order ISO8601]
      rc 0 accepted | 76 duplicate | 2 usage
      --current-head: the producer verified this sha is the PR's current head.
      --head-order:   the PR's updated_at from that same read. A queued row is
      superseded only when its token is strictly older, so a delayed POST that
      verified an older head cannot cancel a head verified after it. Without
      both, nothing is superseded (arrival order is not commit order).
      stdout: {"status":"queued|duplicate","key":...,"id":N,...}
  claim <worker> [--lease S]
      rc 0 claimed | 1 empty
      stdout: the job object
  finish <id> <worker> <verdict>   verdict: go|no_go|cannot_review|unknown
      rc 0 | 1 not owned by worker | 2 usage
  fail <id> <worker> <rc> <class> <message>
      class: transport|quota|review|lease
      rc 0 requeued | 0 dead | 2 usage  (stdout: {"status":"queued|dead",...})
  heartbeat <worker> [--lease S] [--job-id N]
  reap [--lease-grace S]
  stats [--window S]
  dump [--limit N]

Exit codes deliberately match the dispatcher's existing contract so the
workflows and the reconciler need no change:
  0 ok | 2 usage/validation | 76 duplicate refused
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

EX_OK = 0
EX_USAGE = 2
EX_EMPTY = 1
EX_DEDUP_REFUSED = 76

DEFAULT_DB = "/var/lib/hydra-qa/queue.sqlite"

# Retry policy. These are deliberately the same numbers the reconciler already
# uses for its own bounds, so "exhausted" means the same thing in both places.
MAX_TRANSPORT_ATTEMPTS = 12
MAX_QUOTA_ATTEMPTS = 4
MAX_REVIEW_ATTEMPTS = 3
DEFAULT_LEASE_S = 1500  # above the 1200s review timeout, below the 1800s stale budget
LEASE_GRACE_S = 120
QUOTA_BACKOFF_S = 1800
TRANSPORT_BACKOFF_BASE_S = 120
TRANSPORT_BACKOFF_CAP_S = 1800
REVIEW_BACKOFF_BASE_S = 60
REVIEW_BACKOFF_CAP_S = 600

VERDICTS = ("go", "no_go", "cannot_review", "unknown")
FAIL_CLASSES = ("transport", "quota", "review", "lease")

REPO_RE = re.compile(r"^Muso-AI/[A-Za-z0-9._-]+$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")
UID_RE = re.compile(r"^U[A-Z0-9]+$")

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS jobs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  repo            TEXT    NOT NULL,
  pr              INTEGER NOT NULL,
  head_sha        TEXT    NOT NULL,
  requester_uid   TEXT    NOT NULL,
  enqueued_at     INTEGER NOT NULL,
  not_before      INTEGER NOT NULL DEFAULT 0,
  status          TEXT    NOT NULL DEFAULT 'queued',
  attempts        INTEGER NOT NULL DEFAULT 0,
  -- The REVIEW budget, counted separately from `attempts`. `attempts` is every
  -- claim, so a transport retry (gateway unreachable, quota) incremented it too
  -- and silently spent the review budget: with MAX_TRANSPORT_ATTEMPTS=12 and
  -- MAX_REVIEW_ATTEMPTS=3, three transport failures left a job one review
  -- failure from dead-letter, and the three budgets were not independent at
  -- all. Only a turn that actually ran and failed (or a lease that expired
  -- mid-turn) counts here.
  review_attempts INTEGER NOT NULL DEFAULT 0,
  transport_attempts INTEGER NOT NULL DEFAULT 0,
  -- Cumulative COMPLETED reviews for this key, across reopens. `attempts` is a
  -- per-run retry budget and is reset when a done row is reopened, so it cannot
  -- bound re-reviews: without this column every --force would look like the
  -- first one and the documented cap would never fire.
  reviews         INTEGER NOT NULL DEFAULT 0,
  -- When the row most recently entered the queue. `enqueued_at` is the ORIGINAL
  -- arrival and is never rewritten: it is the accounting key that makes
  -- arrivals == open + terminal + lost hold. A reopen moves queued_at only, so
  -- a re-review's wait is measured from the reopen without inventing an arrival.
  queued_at       INTEGER,
  -- The PR's `updated_at` as GitHub reported it when the producer verified this
  -- sha was the current head, stored as the ISO-8601 string GitHub returns.
  -- ISO-8601 UTC sorts lexicographically, so this is a MONOTONIC ordering token
  -- the broker can compare without a clock of its own. It exists because
  -- "current head" is a check-then-act: dispatch A can verify A, head B can be
  -- pushed, dispatch B can verify and enqueue B, and only THEN can A's delayed
  -- POST arrive still claiming current_head. Arrival order cannot break that
  -- tie; the verification order can. Empty means unverified, and an unverified
  -- row is never superseded.
  head_order      TEXT NOT NULL DEFAULT '',
  quota_attempts  INTEGER NOT NULL DEFAULT 0,
  lease_owner     TEXT,
  lease_until     INTEGER,
  last_heartbeat_at INTEGER,
  started_at      INTEGER,
  finished_at     INTEGER,
  verdict         TEXT,
  last_error      TEXT,
  superseded_by   INTEGER,
  UNIQUE(repo, pr, head_sha),
  CHECK (status IN ('queued','running','done','dead','superseded')),
  CHECK (verdict IS NULL OR verdict IN ('go','no_go','cannot_review','unknown'))
);

-- Invariant 3: at most one RUNNING review per PR. This is the constraint the
-- whole "one PR, one active review" guarantee rests on; keep it in the schema
-- so no code path can violate it, however it is refactored later.
CREATE UNIQUE INDEX IF NOT EXISTS one_active_review_per_pr
  ON jobs(repo, pr) WHERE status = 'running';

CREATE INDEX IF NOT EXISTS claimable
  ON jobs(status, not_before, enqueued_at);
CREATE INDEX IF NOT EXISTS by_repo_pr
  ON jobs(repo, pr);

CREATE TABLE IF NOT EXISTS repo_clock (
  repo            TEXT PRIMARY KEY,
  last_served_at  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          INTEGER NOT NULL,
  kind        TEXT    NOT NULL,
  key         TEXT,
  repo        TEXT,
  pr          INTEGER,
  head_sha    TEXT,
  worker      TEXT,
  detail      TEXT
);
CREATE INDEX IF NOT EXISTS events_at ON events(at);
"""


def now_s() -> int:
    return int(time.time())


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_cap(name: str, default: int) -> int:
    """Read a concurrency CAP, failing closed on a malformed value.

    `_env_int` returns the default on a bad value, and every cap's default is 0
    = unlimited. So `QA_BROKER_MAX_RUNNING=bad` (a typo, a stray quote, a
    templating bug) silently removed the ceiling and let every worker claim at
    once against one model route and one GitHub REST budget. A cap that cannot
    be parsed is a misconfiguration, not a request for no cap: raise, so the
    caller answers 500/rc 3 and the worker logs it loudly instead of quietly
    running unbounded.
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ValueError(f"{name}={raw!r} is not an integer; refusing to treat a malformed cap as unlimited") from None
    if value < 0:
        raise ValueError(f"{name}={value} is negative; use 0 for unlimited")
    return value


def _backoff(base: int, cap: int, attempt_n: int) -> int:
    """min(cap, base * 2**(n-1)). n is 1-based: the first retry waits `base`."""
    n = max(1, attempt_n)
    # Cap the exponent before shifting so a corrupt attempt counter cannot
    # produce an astronomically large integer.
    return min(cap, base * (2 ** min(n - 1, 20)))


def retry_delay_s(fail_class: str, transport_n: int, quota_n: int, review_n: int) -> int:
    if fail_class == "quota":
        return QUOTA_BACKOFF_S
    if fail_class == "transport":
        return _backoff(TRANSPORT_BACKOFF_BASE_S, TRANSPORT_BACKOFF_CAP_S, transport_n)
    # review and lease both count against the review budget.
    return _backoff(REVIEW_BACKOFF_BASE_S, REVIEW_BACKOFF_CAP_S, review_n)


def exhausted(fail_class: str, transport_n: int, quota_n: int, review_n: int) -> bool:
    if fail_class == "quota":
        return quota_n >= MAX_QUOTA_ATTEMPTS
    if fail_class == "transport":
        return transport_n >= MAX_TRANSPORT_ATTEMPTS
    return review_n >= MAX_REVIEW_ATTEMPTS


def make_key(repo: str, pr: int, head_sha: str) -> str:
    return f"{repo}#{pr}@{head_sha.lower()}"


def _row_to_job(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "key": make_key(row["repo"], row["pr"], row["head_sha"]),
        "repo": row["repo"],
        "pr": row["pr"],
        "head_sha": row["head_sha"],
        "requester_uid": row["requester_uid"],
        "enqueued_at": row["enqueued_at"],
        "not_before": row["not_before"],
        "status": row["status"],
        "attempts": row["attempts"],
        "review_attempts": row["review_attempts"],
        "transport_attempts": row["transport_attempts"],
        "quota_attempts": row["quota_attempts"],
        "lease_owner": row["lease_owner"],
        "lease_until": row["lease_until"],
        "started_at": row["started_at"],
        "finished_at": row["finished_at"],
        "verdict": row["verdict"],
        "last_error": row["last_error"],
    }


class Broker:
    """The queue. One instance per process; connections are opened per call.

    SQLite connections are not thread-safe by default and this module is used
    as a short-lived CLI, so each operation opens and closes its own connection
    rather than holding one open. That keeps a crashed call from leaving a
    write lock behind.
    """

    def __init__(self, db_path: str | None = None) -> None:
        self.db_path = db_path or os.environ.get("QA_QUEUE_DB") or DEFAULT_DB
        self._ensure_dir()
        with self._conn() as c:
            c.executescript(SCHEMA)
            self._migrate(c)

    @staticmethod
    def _migrate(c: sqlite3.Connection) -> None:
        """Add columns introduced after a database was first created.

        `CREATE TABLE IF NOT EXISTS` is a no-op on an existing file, so a new
        column would silently never appear on a live queue. Each entry is
        idempotent: PRAGMA tells us whether the column is already there.
        """
        have = {r[1] for r in c.execute("PRAGMA table_info(jobs)")}
        for name, decl in (
            # Bounds crash recovery to the heartbeat staleness window instead of
            # the full lease: a SIGKILLed worker holds its job for lease_until
            # (25 min) otherwise, which is most of the wait budget.
            ("last_heartbeat_at", "INTEGER"),
            ("reviews", "INTEGER NOT NULL DEFAULT 0"),
            ("queued_at", "INTEGER"),
            ("head_order", "TEXT NOT NULL DEFAULT ''"),
            ("review_attempts", "INTEGER NOT NULL DEFAULT 0"),
        ):
            if name not in have:
                c.execute(f"ALTER TABLE jobs ADD COLUMN {name} {decl}")
        # Backfill: an existing row's queue entry is its original arrival.
        c.execute("UPDATE jobs SET queued_at=enqueued_at WHERE queued_at IS NULL")

    def _ensure_dir(self) -> None:
        parent = os.path.dirname(os.path.abspath(self.db_path))
        if parent:
            os.makedirs(parent, exist_ok=True)

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30.0, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    # ── events ────────────────────────────────────────────────────────────
    @staticmethod
    def _event(
        conn: sqlite3.Connection,
        kind: str,
        *,
        key: str = "",
        repo: str = "",
        pr: int = 0,
        head_sha: str = "",
        worker: str = "",
        detail: str = "",
        at: int | None = None,
    ) -> None:
        conn.execute(
            "INSERT INTO events(at,kind,key,repo,pr,head_sha,worker,detail)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (at if at is not None else now_s(), kind, key, repo, pr, head_sha, worker, detail),
        )

    # ── enqueue ───────────────────────────────────────────────────────────
    def enqueue(
        self,
        repo: str,
        pr: int,
        head_sha: str,
        requester_uid: str,
        *,
        force: bool = False,
        not_before: int = 0,
        current_head: bool = False,
        head_order: str = "",
    ) -> dict[str, Any]:
        """Accept a review request, or refuse it as a duplicate.

        Returns a dict with status one of:
          queued      a new row was inserted
          duplicate   the same key is already queued/running/done/dead (rc 76)

        `superseded` is NOT an enqueue result: it is the terminal status of a
        QUEUED row that a newer head replaced (see the supersede block below).
        A refused re-enqueue of an already-reviewed key is a `duplicate` with
        `existing_status="done"` and the prior `verdict`, so the supersede
        metric keeps meaning exactly one thing.
        """
        head_sha = head_sha.lower()
        key = make_key(repo, pr, head_sha)
        t = now_s()
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")

            # Invariant 1: the same key is never reviewed twice.
            existing = conn.execute(
                "SELECT * FROM jobs WHERE repo=? AND pr=? AND head_sha=?",
                (repo, pr, head_sha),
            ).fetchone()
            if existing is not None:
                st = existing["status"]
                if st in ("queued", "running", "superseded"):
                    # Record the refusal so stats() can report how many
                    # duplicate requests the broker absorbed.
                    self._event(
                        conn, "duplicate", key=key, repo=repo, pr=pr,
                        head_sha=head_sha,
                        detail=f"existing_status={st} id={existing['id']}", at=t,
                    )
                    conn.execute("COMMIT")
                    return {
                        "status": "duplicate",
                        "key": key,
                        "id": existing["id"],
                        "existing_status": st,
                    }
                if st == "dead":
                    # A dead row is the operator-retry path: the retry budget was
                    # spent on an outage (a dead gateway, a spent quota), and once
                    # that is fixed the PR still has no verdict. Without this a
                    # forced enqueue answered `duplicate` forever and the only
                    # ways out were a new commit or hand-editing the database.
                    #
                    # Only on an EXPLICIT force: an automatic reconciler retry
                    # must not resurrect a job that already exhausted its budget,
                    # or a permanently broken review would spin forever.
                    if not force:
                        self._event(
                            conn, "duplicate", key=key, repo=repo, pr=pr,
                            head_sha=head_sha,
                            detail=f"existing_status=dead id={existing['id']}", at=t,
                        )
                        conn.execute("COMMIT")
                        return {
                            "status": "duplicate",
                            "key": key,
                            "id": existing["id"],
                            "existing_status": "dead",
                        }
                    # Same reopen shape as the done branch: one row per key, the
                    # original `enqueued_at` preserved (it is the lost-job
                    # accounting key), only `queued_at` moved so the wait is
                    # measured from the retry. The event log keeps the history.
                    conn.execute(
                        "UPDATE jobs SET status='queued', not_before=?, attempts=0,"
                        " review_attempts=0, transport_attempts=0, quota_attempts=0,"
                        " lease_owner=NULL,"
                        " lease_until=NULL, started_at=NULL, finished_at=NULL,"
                        " verdict=NULL, last_error=NULL, queued_at=?"
                        " WHERE id=?",
                        (not_before or t, t, existing["id"]),
                    )
                    self._event(
                        conn, "reopen", key=key, repo=repo, pr=pr, head_sha=head_sha,
                        detail=f"force retry of dead/{existing['last_error'] or 'unknown'}",
                        at=t,
                    )
                    conn.execute("COMMIT")
                    return {"status": "queued", "key": key, "id": existing["id"],
                            "reopened": True, "was": "dead"}
                if st == "done":
                    # A GO is terminal. A failing verdict may be re-reviewed on
                    # request (tier-recheck), capped so a loop cannot spin.
                    allowed = _done_review_allowed(existing, force)
                    if not allowed:
                        self._event(
                            conn, "duplicate", key=key, repo=repo, pr=pr,
                            head_sha=head_sha,
                            detail=f"existing_status=done verdict={existing['verdict']}"
                                   f" force={int(force)}", at=t,
                        )
                        conn.execute("COMMIT")
                        return {
                            "status": "duplicate",
                            "key": key,
                            "id": existing["id"],
                            "existing_status": "done",
                            "verdict": existing["verdict"],
                        }
                    # Re-open the row rather than inserting a second one: the
                    # UNIQUE(repo,pr,head_sha) key must stay one row per key so
                    # "never reviewed twice" is checkable by row count.
                    # `enqueued_at` is deliberately NOT rewritten: it is the
                    # original arrival, and the lost-job identity
                    # (arrivals == open + terminal + lost) is computed from it.
                    # Moving it into the current window without adding an
                    # `enqueue` event made lost_window read 0 while a job was
                    # genuinely lost, which silenced the digest's page. Only
                    # `queued_at` moves, so wait time is still measured from the
                    # reopen.
                    conn.execute(
                        "UPDATE jobs SET status='queued', not_before=?, attempts=0,"
                        " review_attempts=0, transport_attempts=0, quota_attempts=0,"
                        " lease_owner=NULL,"
                        " lease_until=NULL, started_at=NULL, finished_at=NULL,"
                        " verdict=NULL, last_error=NULL, queued_at=?"
                        " WHERE id=?",
                        (not_before or t, t, existing["id"]),
                    )
                    self._event(
                        conn, "reopen", key=key, repo=repo, pr=pr, head_sha=head_sha,
                        detail=f"force re-review of done/{existing['verdict']}",
                        at=t,
                    )
                    conn.execute("COMMIT")
                    return {"status": "queued", "key": key, "id": existing["id"], "reopened": True}

            # Invariant 2: a newer head supersedes every older QUEUED row for
            # this PR. A RUNNING older review is left alone (its verdict is
            # still true for the commit it reviewed); the newer row simply
            # waits its turn.
            #
            # ONLY when the producer asserts this sha is the PR's current head.
            # Arrival order is not commit order: a delayed dispatch for an OLDER
            # head arrives after the current one and would otherwise supersede
            # it, leaving the current head with no review at all and the stale
            # head as the only claimable job. The broker cannot see GitHub, so
            # the producer (which can) asserts it; without the assertion we
            # queue the extra review rather than risk cancelling the right one.
            #
            # And only rows this one is provably NEWER than. `current_head` is a
            # check-then-act: A can verify A, B can be pushed, B can verify and
            # enqueue, and only then can A's delayed POST arrive still claiming
            # current_head. Arrival order cannot break that tie, so the producer
            # also carries the PR's `updated_at` from the same read, and a row is
            # superseded only when its token is strictly older. An unverified
            # row (empty token) is never superseded: the cost of an extra review
            # is a wasted turn, the cost of a cancelled one is a missing verdict.
            older = []
            if current_head and head_order:
                older = conn.execute(
                    "SELECT id, head_sha FROM jobs WHERE repo=? AND pr=? AND status='queued'"
                    " AND head_order != '' AND head_order < ?",
                    (repo, pr, head_order),
                ).fetchall()

            cur = conn.execute(
                "INSERT INTO jobs(repo,pr,head_sha,requester_uid,enqueued_at,queued_at,"
                " not_before,head_order,status) VALUES (?,?,?,?,?,?,?,?,'queued')",
                (repo, pr, head_sha, requester_uid, t, t, not_before or t, head_order),
            )
            new_id = int(cur.lastrowid)

            for row in older:
                conn.execute(
                    "UPDATE jobs SET status='superseded', superseded_by=?, finished_at=?"
                    " WHERE id=?",
                    (new_id, t, row["id"]),
                )
                self._event(
                    conn, "supersede", key=make_key(repo, pr, row["head_sha"]),
                    repo=repo, pr=pr, head_sha=row["head_sha"],
                    detail=f"superseded by {key}", at=t,
                )

            self._event(
                conn, "enqueue", key=key, repo=repo, pr=pr, head_sha=head_sha,
                detail=f"requester={requester_uid}"
                       + (f" superseded={len(older)}" if older else ""),
                at=t,
            )
            conn.execute("COMMIT")
            return {
                "status": "queued",
                "key": key,
                "id": new_id,
                "superseded": len(older),
            }
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── claim ─────────────────────────────────────────────────────────────
    def claim(self, worker: str, *, lease: int = DEFAULT_LEASE_S) -> dict[str, Any] | None:
        """Claim the oldest ready job, fairly across repos.

        Ordering: repo_clock.last_served_at ASC first (so a repo that has never
        been served, or was served longest ago, wins), then enqueued_at ASC.
        A repo whose in-flight count is already at its cap is skipped, so one
        busy repo cannot monopolise every worker.
        """
        t = now_s()
        cap = _env_cap("QA_BROKER_PER_REPO_INFLIGHT_CAP", 0)
        # Fleet-wide in-flight cap. The per-repo cap stops one repo monopolising
        # the workers; this one stops the WORKERS monopolising the model route
        # and the GitHub REST budget. Scaling to 24 pods must not mean 24
        # simultaneous reviews against a shared quota, so the cap is enforced
        # here (the single writer) rather than in each pod.
        max_running = _env_cap("QA_BROKER_MAX_RUNNING", 0)
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            if max_running > 0:
                running_now = conn.execute(
                    "SELECT COUNT(*) FROM jobs WHERE status='running'"
                ).fetchone()[0]
                if running_now >= max_running:
                    conn.execute("COMMIT")
                    return None
            # Placeholder order must match the SQL text: not_before first,
            # then the optional per-repo in-flight cap.
            params: list[Any] = [t]
            cap_clause = ""
            if cap > 0:
                cap_clause = (
                    " AND (SELECT COUNT(*) FROM jobs r"
                    "      WHERE r.repo=j.repo AND r.status='running') < ?"
                )
                params.append(cap)
            # A PR that already has a RUNNING review must be skipped entirely,
            # not merely ordered last: the partial unique index
            # (one_active_review_per_pr) would reject the UPDATE and raise
            # IntegrityError, which the HTTP layer reports as an empty claim —
            # so one PR's queued newer head could starve every other PR.
            row = conn.execute(
                "SELECT j.* FROM jobs j"
                " LEFT JOIN repo_clock c ON c.repo=j.repo"
                " WHERE j.status='queued' AND j.not_before<=?"
                " AND NOT EXISTS (SELECT 1 FROM jobs r"
                "                 WHERE r.repo=j.repo AND r.pr=j.pr AND r.status='running')"
                + cap_clause
                + " ORDER BY COALESCE(c.last_served_at,0) ASC, COALESCE(j.queued_at,j.enqueued_at) ASC, j.id ASC"
                " LIMIT 1",
                params,
            ).fetchone()
            if row is None:
                conn.execute("COMMIT")
                return None
            conn.execute(
                "UPDATE jobs SET status='running', lease_owner=?, lease_until=?,"
                " last_heartbeat_at=?, started_at=?, attempts=attempts+1 WHERE id=?",
                (worker, t + lease, t, t, row["id"]),
            )
            conn.execute(
                "INSERT INTO repo_clock(repo,last_served_at) VALUES (?,?)"
                " ON CONFLICT(repo) DO UPDATE SET last_served_at=excluded.last_served_at",
                (row["repo"], t),
            )
            fresh = conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()
            self._event(
                conn, "claim", key=make_key(fresh["repo"], fresh["pr"], fresh["head_sha"]),
                repo=fresh["repo"], pr=fresh["pr"], head_sha=fresh["head_sha"],
                worker=worker, detail=f"attempt={fresh['attempts']} lease={lease}s", at=t,
            )
            conn.execute("COMMIT")
            return _row_to_job(fresh)
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── heartbeat ─────────────────────────────────────────────────────────
    def heartbeat(
        self, worker: str, *, lease: int = DEFAULT_LEASE_S, job_id: int | None = None
    ) -> int:
        """Renew this worker's lease. Returns the row count renewed.

        `job_id` scopes the renewal to the ONE job this process is actually
        working on, and callers should always pass it. Without it the renewal
        covers every running row owned by `worker`, which is wrong the moment a
        worker ID is reused: a container restarted in the same pod can come back
        with the same `<hostname>-<pid>`, claim a different PR, and then renew
        the ABANDONED row's heartbeat forever. The reaper would never requeue
        that PR, so it would sit `running` with no worker behind it — the exact
        silent stall the lease exists to prevent.
        """
        t = now_s()
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            if job_id is None:
                cur = conn.execute(
                    "UPDATE jobs SET lease_until=?, last_heartbeat_at=?"
                    " WHERE status='running' AND lease_owner=?",
                    (t + lease, t, worker),
                )
            else:
                cur = conn.execute(
                    "UPDATE jobs SET lease_until=?, last_heartbeat_at=?"
                    " WHERE status='running' AND lease_owner=? AND id=?",
                    (t + lease, t, worker, job_id),
                )
            n = cur.rowcount
            conn.execute("COMMIT")
            return n
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── finish ────────────────────────────────────────────────────────────
    def finish(self, job_id: int, worker: str, verdict: str) -> dict[str, Any]:
        verdict = verdict.strip().lower().replace("-", "_")
        if verdict not in VERDICTS:
            raise ValueError(f"verdict must be one of {VERDICTS}, got {verdict!r}")
        t = now_s()
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise LookupError(f"no job {job_id}")
            if row["status"] != "running":
                raise LookupError(f"job {job_id} is {row['status']}, not running")
            if row["lease_owner"] != worker:
                raise LookupError(
                    f"job {job_id} is leased to {row['lease_owner']}, not {worker}"
                )
            conn.execute(
                "UPDATE jobs SET status='done', verdict=?, finished_at=?,"
                " lease_owner=NULL, lease_until=NULL, reviews=reviews+1 WHERE id=?",
                (verdict, t, job_id),
            )
            self._event(
                conn, "finish", key=make_key(row["repo"], row["pr"], row["head_sha"]),
                repo=row["repo"], pr=row["pr"], head_sha=row["head_sha"],
                worker=worker, detail=f"verdict={verdict}", at=t,
            )
            conn.execute("COMMIT")
            return {"status": "done", "id": job_id, "verdict": verdict}
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── abandon ───────────────────────────────────────────────────────────
    def abandon(self, job_id: int, worker: str, reason: str) -> dict[str, Any]:
        """Retire a running job as `superseded` without charging an attempt.

        Used when the worker discovers the PR head moved while it was
        reviewing. The turn reviewed the NEWER head (the skill resolves the
        head itself), so this job's head will never get a status from it, and a
        dispatch for the newer head is already on its way. Retrying would
        re-review the newer head, spend a review attempt, and eventually
        dead-letter a PR that is in fact being reviewed.

        `superseded` is terminal and is NOT a failure: it does not increment
        `review_attempts`, does not count as `dead`, and is excluded from the
        lost-job accounting exactly like a superseded queued row.
        """
        t = now_s()
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise LookupError(f"no job {job_id}")
            if row["status"] != "running" or row["lease_owner"] != worker:
                conn.execute("COMMIT")
                return {
                    "status": "not_owner",
                    "id": job_id,
                    "existing_status": row["status"],
                    "owner": row["lease_owner"],
                }
            conn.execute(
                "UPDATE jobs SET status='superseded', finished_at=?,"
                " lease_owner=NULL, lease_until=NULL, last_error=? WHERE id=?",
                (t, reason[:500], job_id),
            )
            self._event(
                conn, "abandon", key=make_key(row["repo"], row["pr"], row["head_sha"]),
                repo=row["repo"], pr=row["pr"], head_sha=row["head_sha"],
                worker=worker, detail=reason[:500], at=t,
            )
            conn.execute("COMMIT")
            return {"status": "superseded", "id": job_id}
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── fail ──────────────────────────────────────────────────────────────
    def fail(
        self, job_id: int, worker: str, rc: int, fail_class: str, message: str
    ) -> dict[str, Any]:
        """Record a failed review turn and either requeue or dead-letter it."""
        fail_class = fail_class.strip().lower()
        if fail_class not in FAIL_CLASSES:
            raise ValueError(f"class must be one of {FAIL_CLASSES}, got {fail_class!r}")
        t = now_s()
        conn = self._conn()
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None:
                raise LookupError(f"no job {job_id}")
            if row["status"] not in ("running", "queued"):
                raise LookupError(f"job {job_id} is {row['status']}, cannot fail it")
            # Ownership. `finish()` already refuses a non-owner; `fail()` must
            # too, or a worker whose lease was reaped and reassigned can requeue
            # the NEW owner's running review (duplicate work, or a dead-letter
            # charged to the wrong attempt). A `queued` row means the reaper
            # already took it back, so there is nothing left for this worker to
            # record: report it and change nothing.
            if row["status"] != "running" or row["lease_owner"] != worker:
                conn.execute("COMMIT")
                return {
                    "status": "not_owner",
                    "id": job_id,
                    "existing_status": row["status"],
                    "owner": row["lease_owner"],
                }

            transport_n = row["transport_attempts"]
            quota_n = row["quota_attempts"]
            review_n = row["review_attempts"]
            if fail_class == "transport":
                transport_n += 1
            elif fail_class == "quota":
                quota_n += 1
            else:
                # review and lease: the turn ran (or was cut short mid-turn), so
                # this is a review-budget failure. Counted here, NOT taken from
                # `attempts`, so transport retries cannot spend this budget.
                review_n += 1

            dead = exhausted(fail_class, transport_n, quota_n, review_n)
            if dead:
                conn.execute(
                    "UPDATE jobs SET status='dead', finished_at=?, lease_owner=NULL,"
                    " lease_until=NULL, last_error=?, transport_attempts=?,"
                    " quota_attempts=?, review_attempts=? WHERE id=?",
                    (t, _truncate(message), transport_n, quota_n, review_n, job_id),
                )
                self._event(
                    conn, "dead", key=make_key(row["repo"], row["pr"], row["head_sha"]),
                    repo=row["repo"], pr=row["pr"], head_sha=row["head_sha"],
                    worker=worker,
                    detail=f"class={fail_class} rc={rc} attempts={review_n}"
                           f" transport={transport_n} quota={quota_n} err={_truncate(message, 200)}",
                    at=t,
                )
                conn.execute("COMMIT")
                # `review_rc`, not `rc`: `rc` is the TRANSPORT result on every
                # broker answer (0 ok, 1 empty, 2 usage, 3 internal, 76 dedup).
                # Reusing it for the review turn's exit code made a successful
                # /fail answer read as rc 1 = "nothing claimed" to the worker.
                return {"status": "dead", "id": job_id, "class": fail_class, "review_rc": rc}

            delay = retry_delay_s(fail_class, transport_n, quota_n, review_n)
            conn.execute(
                "UPDATE jobs SET status='queued', not_before=?, lease_owner=NULL,"
                " lease_until=NULL, last_error=?, transport_attempts=?,"
                " quota_attempts=?, review_attempts=? WHERE id=?",
                (t + delay, _truncate(message), transport_n, quota_n, review_n, job_id),
            )
            self._event(
                conn, "retry", key=make_key(row["repo"], row["pr"], row["head_sha"]),
                repo=row["repo"], pr=row["pr"], head_sha=row["head_sha"],
                worker=worker,
                detail=f"class={fail_class} rc={rc} retry_in={delay}s"
                       f" attempts={review_n} transport={transport_n} quota={quota_n}",
                at=t,
            )
            conn.execute("COMMIT")
            return {
                "status": "queued",
                "id": job_id,
                "class": fail_class,
                "review_rc": rc,
                "retry_in": delay,
            }
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ── reap ──────────────────────────────────────────────────────────────
    def reap(self, *, grace: int = LEASE_GRACE_S) -> dict[str, Any]:
        """Return dead reviewers' rows to the queue; dead-letter those that run out.

        A row is dead when EITHER
          * its lease expired (`lease_until < now`), or
          * its heartbeat went stale (`last_heartbeat_at < now - stale`).

        The second condition is what makes a restart cheap. A worker killed with
        SIGKILL (a pod eviction, a node drain, a `kubectl delete --force`) never
        releases its lease, so waiting for `lease_until` would hold that PR for
        the whole lease (25 min) — most of the wait budget the queue exists to
        protect. The worker heartbeats every 120 s, so a heartbeat older than
        QA_BROKER_HEARTBEAT_STALE_S (default 360 s = 3 missed beats) means the
        owner is gone, whatever the lease says.

        Either way the reviewer started and died, which counts as a review
        attempt (claim already incremented it), so a crash loop exhausts the
        review budget and dead-letters rather than spinning forever.
        """
        t = now_s()
        stale = _env_int("QA_BROKER_HEARTBEAT_STALE_S", 360)
        conn = self._conn()
        requeued: list[dict[str, Any]] = []
        dead: list[dict[str, Any]] = []
        try:
            conn.execute("BEGIN IMMEDIATE")
            rows = conn.execute(
                "SELECT * FROM jobs WHERE status='running' AND lease_until IS NOT NULL"
                " AND (lease_until < ?"
                "      OR (last_heartbeat_at IS NOT NULL AND last_heartbeat_at < ?))",
                (t, t - stale),
            ).fetchall()
            for row in rows:
                key = make_key(row["repo"], row["pr"], row["head_sha"])
                # Name the reason: "lease expired" and "heartbeat stale" are
                # different failures and the operator needs to tell them apart.
                why = (
                    "lease expired"
                    if (row["lease_until"] or 0) < t
                    else "heartbeat stale"
                )
                # A lease that expired mid-turn is a REVIEW-budget failure: the
                # turn ran and was cut short. Counted on review_attempts, the
                # same counter fail() uses, so the two paths share one budget
                # and neither can be spent by transport retries.
                review_n = int(row["review_attempts"] or 0) + 1
                if exhausted("lease", row["transport_attempts"], row["quota_attempts"], review_n):
                    conn.execute(
                        "UPDATE jobs SET status='dead', finished_at=?, lease_owner=NULL,"
                        " lease_until=NULL, last_error=?, review_attempts=? WHERE id=?",
                        (t, why, review_n, row["id"]),
                    )
                    self._event(
                        conn, "dead", key=key, repo=row["repo"], pr=row["pr"],
                        head_sha=row["head_sha"], worker=row["lease_owner"] or "",
                        detail=f"{why}, review_attempts={review_n} exhausted", at=t,
                    )
                    dead.append({"id": row["id"], "key": key})
                    continue
                delay = retry_delay_s("lease", row["transport_attempts"], row["quota_attempts"], review_n)
                conn.execute(
                    "UPDATE jobs SET status='queued', not_before=?, lease_owner=NULL,"
                    " lease_until=NULL, last_error=?, review_attempts=? WHERE id=?",
                    (t + delay, why, review_n, row["id"]),
                )
                self._event(
                    conn, "lease_expired", key=key, repo=row["repo"], pr=row["pr"],
                    head_sha=row["head_sha"], worker=row["lease_owner"] or "",
                    detail=f"{why}, review_attempts={review_n} requeue_in={delay}s", at=t,
                )
                requeued.append({"id": row["id"], "key": key, "retry_in": delay})
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()
        return {"requeued": requeued, "dead": dead, "count": len(requeued) + len(dead)}

    # ── stats ─────────────────────────────────────────────────────────────
    def stats(self, *, window: int = 3600) -> dict[str, Any]:
        """Queue depth, wait times, verdict counts and the dedupe metrics.

        The dedupe counters are first-class because "the same key is never
        reviewed twice" is a property that has to be observable, not just
        asserted in a test.
        """
        t = now_s()
        since = t - window
        conn = self._conn()
        try:
            def one(sql: str, args: tuple[Any, ...] = ()) -> Any:
                r = conn.execute(sql, args).fetchone()
                return r[0] if r is not None else 0

            depth = one("SELECT COUNT(*) FROM jobs WHERE status='queued'")
            running = one("SELECT COUNT(*) FROM jobs WHERE status='running'")
            dead = one("SELECT COUNT(*) FROM jobs WHERE status='dead'")
            oldest = one("SELECT MIN(COALESCE(queued_at,enqueued_at)) FROM jobs WHERE status='queued'") or t
            oldest_age = max(0, t - int(oldest)) if depth else 0

            # Wait = claim time minus enqueue time, for reviews claimed in the
            # window. p50/p95 over that sample.
            waits = [
                r[0]
                for r in conn.execute(
                    "SELECT started_at - COALESCE(queued_at,enqueued_at) FROM jobs"
                    " WHERE started_at IS NOT NULL AND started_at>=?",
                    (since,),
                )
                if r[0] is not None and r[0] >= 0
            ]
            waits.sort()
            p50 = _pct(waits, 50)
            p95 = _pct(waits, 95)

            done_w = one(
                "SELECT COUNT(*) FROM jobs WHERE status='done' AND finished_at>=?", (since,)
            )

            # ── lost jobs ────────────────────────────────────────────────
            # Every ARRIVAL is either still open (queued/running) or terminal
            # (done/dead/superseded). If those do not add up, a job went
            # missing — the one failure mode a durable queue must never have
            # silently.
            #
            # Arrivals are counted from the append-only `events` log, NOT from
            # the jobs table: counting both sides from `jobs` makes the
            # subtraction identically zero, so a deleted row would be invisible
            # (the metric would be tautological and useless). The events log is
            # written in the same transaction as the insert, so it is the
            # durable record of what was accepted.
            def _lost(since_ts: int | None) -> int:
                # Both sides must cover the SAME population. Counting arrivals in
                # the window while counting every job ever stored makes the
                # result negative as soon as old healthy rows exist (10 old rows
                # + 1 newly lost = 1 - 10 = -9), which would mask a real loss and
                # silence the digest's page. So the job counts are windowed on
                # enqueued_at too: arrivals_window = open_window + term_window +
                # lost_window, and the all-time form is the same identity.
                ev_cond = "" if since_ts is None else " AND at>=?"
                job_cond = "" if since_ts is None else " AND enqueued_at>=?"
                args: tuple[Any, ...] = () if since_ts is None else (since_ts,)
                arrivals = one(
                    "SELECT COUNT(*) FROM events WHERE kind='enqueue'" + ev_cond, args
                )
                open_ = one(
                    "SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running')"
                    + job_cond, args,
                )
                term = one(
                    "SELECT COUNT(*) FROM jobs"
                    " WHERE status IN ('done','dead','superseded')" + job_cond, args,
                )
                return int(arrivals) - int(open_) - int(term)

            lost_window = _lost(since)
            lost_total = _lost(None)
            verdicts = {v: 0 for v in VERDICTS}
            for r in conn.execute(
                "SELECT verdict, COUNT(*) FROM jobs WHERE status='done'"
                " AND finished_at>=? AND verdict IS NOT NULL GROUP BY verdict",
                (since,),
            ):
                verdicts[r[0]] = r[1]

            # Dedupe metrics, straight from the events log.
            def ev(kind: str) -> int:
                return one(
                    "SELECT COUNT(*) FROM events WHERE kind=? AND at>=?", (kind, since)
                )

            # The one-active-review-per-PR invariant, measured: the maximum
            # number of simultaneously running rows any single PR has had in
            # the window. Anything above 1 means the invariant was violated.
            per_pr_max = one(
                "SELECT COALESCE(MAX(n),0) FROM ("
                "  SELECT repo, pr, COUNT(*) AS n FROM jobs"
                "  WHERE status='running' GROUP BY repo, pr)"
            )

            by_repo = []
            for r in conn.execute(
                "SELECT repo, COUNT(*) AS depth,"
                "       MIN(COALESCE(queued_at,enqueued_at)) AS oldest_at"
                "  FROM jobs WHERE status='queued' GROUP BY repo"
                " ORDER BY depth DESC",
            ):
                by_repo.append(
                    {
                        "repo": r["repo"],
                        "depth": r["depth"],
                        "oldest_age_s": max(0, t - int(r["oldest_at"] or t)),
                    }
                )

            return {
                "ok": True,
                "at": t,
                "window_s": window,
                "depth": depth,
                "running": running,
                "dead": dead,
                "oldest_queued_age_s": oldest_age,
                "wait_p50_s": p50,
                "wait_p95_s": p95,
                "done_window": done_w,
                "enqueued_window": one(
                    "SELECT COUNT(*) FROM events WHERE kind='enqueue' AND at>=?",
                    (since,),
                ),
                "lost_window": lost_window,
                "lost_total": lost_total,
                "verdicts": verdicts,
                "dedupe": {
                    "duplicates_dropped": ev("duplicate"),
                    "superseded": ev("supersede"),
                    "lease_expired": ev("lease_expired"),
                    "active_reviews_per_pr_max": int(per_pr_max),
                },
                "by_repo": by_repo,
            }
        finally:
            conn.close()

    # ── dump ──────────────────────────────────────────────────────────────
    def dump(self, *, limit: int = 50) -> list[dict[str, Any]]:
        conn = self._conn()
        try:
            return [
                _row_to_job(r)
                for r in conn.execute(
                    "SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,)
                )
            ]
        finally:
            conn.close()


# ── HTTP service mode ─────────────────────────────────────────────────────
# A worker pod cannot mount the broker's SQLite file (SQLite over a network
# filesystem is not safe), so the broker also runs as a tiny HTTP service and
# the worker calls it. The endpoints mirror the CLI one-for-one, so the same
# contract and the same tests describe both. Everything except GET /healthz and
# GET /stats is a POST with a JSON body and returns the CLI's own JSON.
#
# This is deliberately a stdlib ThreadingHTTPServer: one dependency fewer to
# patch, and the broker's work is all in SQLite anyway. Bind is 0.0.0.0 so the
# k8s Service can reach it; in production it sits behind the ClusterIP Service
# and is never exposed outside the namespace.
#
# HTTP status mapping (the CLI's exit codes are NOT valid HTTP status lines --
# `76` would be written as "HTTP/1.1 76", which curl reports as a failed
# connection rather than a duplicate). The body always carries the CLI rc so a
# caller can use either layer:
#   200 ok / accepted            -> rc 0
#   200 {"rc":1} nothing to claim -> rc 1  (NOT 204: a 204 cannot carry the body
#                                            the worker reads, and an empty body
#                                            parses as rc 2 = malformed)
#   400 bad request/validation   -> rc 2
#   404 unknown job/route        -> rc 2
#   409 duplicate or superseded  -> rc 76   ({"status":..., "rc":76})
#   500 internal                 -> rc 3
# `internal` is deliberately distinct from `empty`: a broker that cannot read
# its own store must never look like an idle queue, or accepted PRs wait with no
# worker error anywhere. The worker treats rc 3 as a loud, backed-off failure
# and rc 1 as "nothing to do".
HTTP_RC = {"ok": 0, "empty": 1, "usage": 2, "internal": 3, "dedup": 76}


def _rc_body(obj: Any, rc: int) -> Any:
    """Attach the CLI-equivalent rc to a JSON body so HTTP and CLI agree."""
    if isinstance(obj, dict) and "rc" not in obj:
        out = dict(obj)
        out["rc"] = rc
        return out
    return obj
class _BrokerHandler(BaseHTTPRequestHandler):
    broker: "Broker"  # set by serve()

    server_version = "qa-broker/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        # The default writes to stderr in a format that collides with our JSON
        # logs; keep it one line and quiet.
        sys.stderr.write("qa-broker-http: " + (fmt % args) + "\n")

    def _send(self, code: int, obj: Any) -> None:
        body = json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        raw = self.rfile.read(n)
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            raise ValueError("body is not valid JSON") from None
        if not isinstance(obj, dict):
            raise ValueError("body must be a JSON object")
        return obj

    def _handle(self, fn) -> None:  # noqa: ANN001
        try:
            code, obj = fn()
        except (ValueError, KeyError) as exc:
            self._send(400, {"ok": False, "error": str(exc), "rc": HTTP_RC["usage"]})
            return
        except LookupError as exc:
            self._send(404, {"ok": False, "error": str(exc), "rc": HTTP_RC["usage"]})
            return
        except sqlite3.IntegrityError as exc:
            # The unique index firing means another worker won the race: the
            # worker should simply ask again, so this is "nothing claimed" (rc 1),
            # not a duplicate refusal.
            self._send(409, {"ok": False, "error": f"constraint: {exc}", "rc": HTTP_RC["empty"]})
            return
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": f"{type(exc).__name__}: {exc}", "rc": HTTP_RC["internal"]})
            return
        self._send(code, obj)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._send(200, {"ok": True})
            return
        if path == "/stats":
            window = _query_int(self.path, "window", 3600)
            self._handle(lambda: (200, self.broker.stats(window=window)))
            return
        self._send(404, {"ok": False, "error": f"no GET {path}"})

    def _authorized(self) -> bool:
        """Gate every MUTATING request.

        Without this, any pod that can reach the service can POST /claim and
        /finish with a worker name of its choosing, record a `go` for a PR that
        was never reviewed, and consume the job so the real review never runs.
        The queue is the only thing standing between a PR and a verdict, so an
        unauthenticated write is a way to forge one.

        Fail closed: with no QA_BROKER_TOKEN configured the broker refuses
        mutations outright rather than serving them openly. The escape hatch is
        explicit (QA_BROKER_ALLOW_UNAUTHENTICATED=1) and exists for local CLI
        use and the test suite, never for a deployment.
        """
        expected = os.environ.get("QA_BROKER_TOKEN", "").strip()
        if not expected:
            if os.environ.get("QA_BROKER_ALLOW_UNAUTHENTICATED", "") == "1":
                return True
            self._send(503, {
                "ok": False,
                "error": "broker has no QA_BROKER_TOKEN; refusing mutations "
                         "(set QA_BROKER_ALLOW_UNAUTHENTICATED=1 only for local use)",
                "rc": HTTP_RC["internal"],
            })
            return False
        presented = self.headers.get("X-QA-Broker-Token", "")
        if not presented:
            auth = self.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                presented = auth[7:].strip()
        if not hmac.compare_digest(presented, expected):
            self._send(401, {"ok": False, "error": "bad or missing broker token",
                             "rc": HTTP_RC["usage"]})
            return False
        return True

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        b = self.broker
        if not self._authorized():
            return
        try:
            body = self._read_json()
        except ValueError as exc:
            self._send(400, {"ok": False, "error": str(exc)})
            return

        if path == "/enqueue":
            def _enq():
                repo, pr, sha = _validate(
                    body.get("repo", ""), str(body.get("pr", "")),
                    body.get("head_sha", ""), body.get("requester_uid", ""),
                )
                res = b.enqueue(
                    repo, pr, sha, body["requester_uid"],
                    force=bool(body.get("force")),
                    not_before=int(body.get("not_before") or 0),
                    current_head=bool(body.get("current_head")),
                    head_order=str(body.get("head_order") or ""),
                )
                if res["status"] in ("duplicate", "superseded"):
                    return 409, _rc_body(res, HTTP_RC["dedup"])
                return 200, _rc_body(res, HTTP_RC["ok"])
            self._handle(_enq)
            return

        if path == "/claim":
            def _claim():
                worker = body.get("worker") or "worker"
                lease = int(body.get("lease") or DEFAULT_LEASE_S)
                job = b.claim(worker, lease=lease)
                if job:
                    return 200, _rc_body(job, HTTP_RC["ok"])
                # 200 with an explicit rc, NOT 204: a 204 cannot carry a body,
                # and the worker reads the body's rc. An empty body parses as
                # rc 2 ("malformed"), which an idle worker logs as an error
                # forever and which never lets a one-shot worker exit.
                return 200, {"rc": HTTP_RC["empty"], "status": "empty"}
            self._handle(_claim)
            return

        if path == "/heartbeat":
            self._handle(lambda: (
                200,
                {"renewed": b.heartbeat(
                    body.get("worker", ""),
                    lease=int(body.get("lease") or DEFAULT_LEASE_S),
                    job_id=(int(body["job_id"]) if body.get("job_id") is not None else None),
                )},
            ))
            return

        # Every mutating answer carries an explicit `rc`. The worker treats a
        # body without one as malformed (rc 2), so omitting it here made a
        # SUCCESSFUL finish/fail log a false broker refusal.
        if path == "/finish":
            self._handle(lambda: (
                200,
                _rc_body(
                    b.finish(int(body["id"]), body.get("worker", ""), body.get("verdict", "")),
                    HTTP_RC["ok"],
                ),
            ))
            return

        if path == "/abandon":
            self._handle(lambda: (
                200,
                _rc_body(
                    b.abandon(int(body["id"]), body.get("worker", ""), body.get("reason", "")),
                    HTTP_RC["ok"],
                ),
            ))
            return

        if path == "/fail":
            self._handle(lambda: (
                200,
                _rc_body(
                    b.fail(
                        int(body["id"]), body.get("worker", ""), int(body.get("rc") or 1),
                        body.get("class", "review"), body.get("message", ""),
                    ),
                    HTTP_RC["ok"],
                ),
            ))
            return

        if path == "/reap":
            self._handle(lambda: (200, b.reap(grace=int(body.get("grace") or LEASE_GRACE_S))))
            return

        self._send(404, {"ok": False, "error": f"no POST {path}"})


def _query_int(path: str, name: str, default: int) -> int:
    if "?" not in path:
        return default
    for part in path.split("?", 1)[1].split("&"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if k == name:
            try:
                return int(v)
            except ValueError:
                return default
    return default


def _reaper_loop(broker: "Broker", interval: int, stop: threading.Event) -> None:
    """Reap on a timer, inside the broker process.

    The reaper must run somewhere durable. A worker cannot own it (a worker is
    exactly the thing that dies), and the digest is an hourly cron that may not
    be installed. So the broker reaps itself: it is the one process whose whole
    job is to be up, and it is the single writer, so the reap is serialized with
    every claim by construction.
    """
    while not stop.wait(interval):
        try:
            res = broker.reap()
            if res.get("requeued") or res.get("dead"):
                sys.stderr.write(
                    f"qa-broker: reaped requeued={res.get('requeued')} dead={res.get('dead')}\n"
                )
        except Exception as exc:  # noqa: BLE001
            # A reaper failure must never take the service down: the queue is
            # still serving claims, and the next tick retries.
            sys.stderr.write(f"qa-broker: reap failed: {type(exc).__name__}: {exc}\n")


def serve(db_path: str | None = None, host: str = "0.0.0.0", port: int = 8080) -> None:
    """Run the broker as an HTTP service. Blocks until killed."""
    _BrokerHandler.broker = Broker(db_path)
    httpd = ThreadingHTTPServer((host, port), _BrokerHandler)
    httpd.daemon_threads = True
    # Without this, a killed worker's row stays `running` forever: depth reads
    # zero, no replacement worker can claim it, and the PR is lost operationally
    # even though the queue is intact.
    stop = threading.Event()
    interval = _env_int("QA_BROKER_REAP_INTERVAL_S", 60)
    reaper = threading.Thread(
        target=_reaper_loop, args=(_BrokerHandler.broker, interval, stop),
        name="qa-broker-reaper", daemon=True,
    )
    reaper.start()
    sys.stderr.write(
        f"qa-broker: serving on {host}:{port} db={_BrokerHandler.broker.db_path}"
        f" reap_interval={interval}s\n"
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        httpd.server_close()


def _done_review_allowed(row: sqlite3.Row, force: bool) -> bool:
    """Decide whether a done key may be re-reviewed."""
    mode = os.environ.get("QA_BROKER_DEDUPE_DONE", "go-only").strip().lower()
    if mode in ("off", "none", "0", "false"):
        return True
    verdict = (row["verdict"] or "").lower()
    if verdict == "go":
        # A GO is the normal terminal state; only an explicit opt-out reopens it.
        return False
    if not force:
        return False
    cap = _env_int("QA_BROKER_MAX_REVIEWS_PER_KEY", 2)
    # `reviews` is the cumulative count of COMPLETED reviews for this key. It is
    # deliberately not `attempts`: reopening resets the per-run retry budget, so
    # an attempts-based cap would let every --force look like the first one.
    return int(row["reviews"] or 0) < cap


def _pct(sorted_vals: list[int], pct: int) -> int:
    if not sorted_vals:
        return 0
    # nearest-rank: ceil(pct/100 * n), clamped into range.
    n = len(sorted_vals)
    idx = max(0, min(n - 1, (pct * n + 99) // 100 - 1))
    return int(sorted_vals[idx])


def _truncate(s: str, n: int = 300) -> str:
    s = (s or "").strip().replace("\n", " ")
    return s if len(s) <= n else s[: n - 1] + "…"


def _validate(repo: str, pr: str, sha: str, uid: str) -> tuple[str, int, str]:
    if not REPO_RE.match(repo):
        raise ValueError(f"repo must be Muso-AI/<name>, got {repo!r}")
    if not str(pr).isdigit():
        raise ValueError(f"pr must be numeric, got {pr!r}")
    if not SHA_RE.match(sha):
        raise ValueError(f"head_sha must be 7-40 hex chars, got {sha!r}")
    if not UID_RE.match(uid):
        raise ValueError(f"requester_uid must be a Slack UID (U...), got {uid!r}")
    return repo, int(pr), sha.lower()


def _out(obj: Any) -> None:
    json.dump(obj, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="qa_broker.py",
        description="Durable, de-duplicating QA review queue.",
    )
    p.add_argument("--db", default=None, help="sqlite path (default QA_QUEUE_DB or "
                                              "/var/lib/hydra-qa/queue.sqlite)")
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("enqueue", help="request a review of one commit")
    e.add_argument("repo")
    e.add_argument("pr")
    e.add_argument("head_sha")
    e.add_argument("requester_uid")
    e.add_argument("--force", action="store_true",
                   help="re-review a key whose last verdict failed (capped)")
    e.add_argument("--not-before", type=int, default=0,
                   help="earliest epoch second this job may be claimed")
    e.add_argument("--current-head", action="store_true",
                   help="the producer verified this sha is the PR's current head, "
                        "so it may supersede queued older heads (arrival order is "
                        "not commit order: a delayed older dispatch must not "
                        "cancel the current head's review)")
    e.add_argument("--head-order", default="",
                   help="the PR's updated_at (ISO-8601) from the same read that "
                        "verified the head; a monotonic token so a delayed POST "
                        "cannot supersede a head verified after it")

    c = sub.add_parser("claim", help="claim the oldest ready job")
    c.add_argument("worker")
    c.add_argument("--lease", type=int, default=DEFAULT_LEASE_S)

    h = sub.add_parser("heartbeat", help="renew this worker's lease")
    h.add_argument("worker")
    h.add_argument("--lease", type=int, default=DEFAULT_LEASE_S)
    h.add_argument("--job-id", type=int, default=None,
                   help="renew only this job (always pass it: an unscoped "
                        "renewal also revives an abandoned row owned by a "
                        "reused worker id)")

    f = sub.add_parser("finish", help="mark a claimed job done with a verdict")
    f.add_argument("id", type=int)
    f.add_argument("worker")
    f.add_argument("verdict")

    ab = sub.add_parser(
        "abandon",
        help="retire a running job as superseded (the head moved); charges no attempt",
    )
    ab.add_argument("id", type=int)
    ab.add_argument("worker")
    ab.add_argument("reason", nargs="?", default="")

    fl = sub.add_parser("fail", help="record a failed turn; requeue or dead-letter")
    fl.add_argument("id", type=int)
    fl.add_argument("worker")
    fl.add_argument("rc", type=int)
    fl.add_argument("fail_class")
    fl.add_argument("message", nargs="?", default="")

    r = sub.add_parser("reap", help="requeue jobs whose lease expired or heartbeat went stale")
    r.add_argument("--grace", type=int, default=LEASE_GRACE_S)

    s = sub.add_parser("stats", help="queue metrics as JSON")
    s.add_argument("--window", type=int, default=3600)

    d = sub.add_parser("dump", help="recent rows as JSON")
    d.add_argument("--limit", type=int, default=50)

    sv = sub.add_parser("serve", help="run as an HTTP service")
    sv.add_argument("--host", default="0.0.0.0")
    sv.add_argument("--port", type=int, default=int(os.environ.get("QA_BROKER_PORT", "8080")))

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd == "serve":
        try:
            serve(args.db, host=args.host, port=args.port)
        except OSError as exc:
            sys.stderr.write(f"qa_broker: cannot serve: {exc}\n")
            return EX_USAGE
        return EX_OK
    try:
        broker = Broker(args.db)
    except Exception as exc:  # noqa: BLE001 - surface any open/migrate failure
        sys.stderr.write(f"qa_broker: cannot open queue: {exc}\n")
        return EX_USAGE

    try:
        if args.cmd == "enqueue":
            repo, pr, sha = _validate(args.repo, args.pr, args.head_sha, args.requester_uid)
            res = broker.enqueue(
                repo, pr, sha, args.requester_uid,
                force=args.force, not_before=args.not_before,
                current_head=args.current_head, head_order=args.head_order,
            )
            _out(res)
            return EX_DEDUP_REFUSED if res["status"] in ("duplicate", "superseded") else EX_OK

        if args.cmd == "claim":
            job = broker.claim(args.worker, lease=args.lease)
            if job is None:
                return EX_EMPTY
            _out(job)
            return EX_OK

        if args.cmd == "heartbeat":
            _out({"renewed": broker.heartbeat(
                args.worker, lease=args.lease, job_id=args.job_id)})
            return EX_OK

        if args.cmd == "finish":
            _out(broker.finish(args.id, args.worker, args.verdict))
            return EX_OK

        if args.cmd == "abandon":
            _out(broker.abandon(args.id, args.worker, args.reason))
            return EX_OK

        if args.cmd == "fail":
            _out(broker.fail(args.id, args.worker, args.rc, args.fail_class, args.message))
            return EX_OK

        if args.cmd == "reap":
            _out(broker.reap(grace=args.grace))
            return EX_OK

        if args.cmd == "stats":
            _out(broker.stats(window=args.window))
            return EX_OK

        if args.cmd == "dump":
            _out(broker.dump(limit=args.limit))
            return EX_OK
    except (ValueError, LookupError) as exc:
        sys.stderr.write(f"qa_broker: {exc}\n")
        return EX_USAGE
    except sqlite3.IntegrityError as exc:
        # The partial unique index firing is a real race the caller must handle:
        # another worker claimed the PR between our read and our write. Report
        # it as "empty" so the worker simply asks again.
        sys.stderr.write(f"qa_broker: constraint: {exc}\n")
        return EX_EMPTY

    sys.stderr.write("qa_broker: unknown command\n")
    return EX_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
