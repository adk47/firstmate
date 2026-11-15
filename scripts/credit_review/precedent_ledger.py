#!/usr/bin/env python3
"""The decision rows of precedent_v1's approvals, in the node-8 credit-review ledger.

precedent_v1 (prev2.js) approves a credit request in core's Postgres, from inside a core-backend
pod. Until this module it wrote nothing to the ledger's `decisions` / `decision_outcomes`, so every
count of approvals read from the ledger (`applied_1h` is `decision_outcomes` with outcome
`approved`) left its approvals out: 0 rows here against 10,384 approvals in core on 2026-11-15.

THE TWO STORES CANNOT SHARE A TRANSACTION. The approval is a row in core's Postgres, written by a
pod; the ledger is a SQLite file on node-8 that the pod cannot open. There is no commit that
covers both. What this module gives instead is an order, and a reader that closes it:

  1. `claim`      BEFORE the core write: one `precedent_claims` row per request the run is about
                  to approve (request id, run id, the precedent it matched, claimed_at). A claim
                  is not an approval and no approval count reads it.
  2. the core write (prev2.js). Not this module's, and never made from here.
  3. `reconcile`  reads core, read-only, for every open claim and closes it. `landed`: core holds
                  the approval under the claim's run, so the request gets its decision row, its
                  `approved` outcome and its move to APPROVED, in the one SQLite transaction that
                  closes the claim. `not_landed`: core does not, so the claim is closed with what
                  core said and nothing else is written. An approval row therefore exists only
                  for an approval core holds.

Why the claim is its own table and not an early `decisions` row: `decisions` is append-only
(triggers refuse UPDATE and DELETE), and seven readers act on a request's NEWEST row there (the
decider's hold and documented-UVN reads, uvn_status's partial marker, stage 2's held rows,
score_approve, doc_measure, proof_review). A claim whose write did not land would stay in that
table for good as the request's newest row, an `approve` over the hold or the partial approval it
is still under.

`reconcile` does not depend on a claim having been written. It also takes the ids of a
PREV2_RESULT line (`--result`) and every precedent approval core changed in the last N hours
(`--since-hours`), so an approval made by a prev2.js that names no batch still gets its row. That
is the case today: see "What is not here".

  precedent_ledger.py claim [LINE]       LINE or stdin carries the plan line (PLAN_MARKER). Exit 0
                                         only when every request of the plan holds a claim: the
                                         caller starts the core write on 0 and on nothing else.
  precedent_ledger.py reconcile          closes open claims. `--result [LINE]` adds a result
                                         line's ids, `--since-hours N` adds core's recent ones.
                                         /etc/hydra/precedent-ledger.disabled stops it (exit 0).
  precedent_ledger.py backfill           every precedent approval core holds, all time, that has
                                         no row here. Prints the plan and writes nothing;
                                         `--apply` inserts them, each marked with the batch id.
                                         A second run inserts none.
  precedent_ledger.py report             what this module wrote, and what is still open. Reads only.

WHAT A ROW CARRIES. `decisions`: run_id (core's `metadata.approval.run`), decided_at (core's
`approval.at`, never the time this ran), request_id, decision `approve`, mode `apply`,
evidence_kind `precedent` (the path), and in `reason` the precedent it matched. `profile_id` and
`user_id` stay NULL on purpose: a profile id would put the request in verify_notify's customer
note audience, and a user id would count it against the decider's per-user daily caps.

WHICH PRECEDENT. A claim names its request's own precedent ids. Core does not: prev2.js writes
the whole batch's precedent sets into every row of the batch (`precedent_ids` is one array per
request approved in that statement, with nothing saying which is whose). So a row written
without a claim names its precedent ids only when its batch was one request; otherwise its
reason says how many sets core recorded and that core does not say which is this request's.

WHICH RUN. `metadata.approval.run`, when core recorded one. The first two batches did not
(2026-11-10T12:22:56Z and 12:38:44Z, 9,465 of the 10,384 approvals core held on 2026-11-15): their
rows carry `prev-unnamed-<approval time>`, which names the batch by the one time its UPDATE gave
every row, and their reason says core recorded no run name.

WHAT IS NOT HERE. prev2.js is not in this repository: node-8 runs /root/prev2.js, a file in no
repository, and its tracked copy is https://github.com/Muso-AI/hydra/pull/1967. It prints no plan
line, so nothing produces step 1's input yet, and the unit that would run 1, 2, 3 in order is a
host file too. Until both exist, every row comes from `reconcile --since-hours` or `backfill`,
which is step 3 without step 1: correct, and later than a claim would make it.

Core is read through the connector's read-only passthrough and never written. Nothing here
decides a request. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, NamedTuple

_SCRIPTS = Path(__file__).resolve().parents[1]
if str(_SCRIPTS) not in sys.path:  # run as a file (`python3 precedent_ledger.py`), not only as a package
    sys.path.insert(0, str(_SCRIPTS))

from credit_review import ledger_open, reconcile_approved, request_state  # noqa: E402 - after the path line above
from credit_review.reconcile_approved import CoreUnread, LedgerRefused  # noqa: E402

LEDGER = reconcile_approved.LEDGER
PLAN_MARKER = "PREV2_PLAN"
VIA = "precedent_v1"
DECISION_PATH = "precedent"   # decisions.evidence_kind: the path that approved
TERMINAL = reconcile_approved.TERMINAL
ACTOR = reconcile_approved.ACTOR
BACKFILL_ACTOR = "precedent-backfill"
# The run id of an approval core recorded no run name for, followed by its approval time. One
# UPDATE stamps its whole batch with one `now()`, so the time names the batch.
UNNAMED_RUN = "prev-unnamed-"

# The claims this module owns. Created here on a write open and nowhere else: a table only one
# tool reads is that tool's to create (every read-only reader of the ledger refuses a ledger
# that lacks a table `verify_ledger.connect()` would add).
CLAIMS_DDL = """
CREATE TABLE IF NOT EXISTS precedent_claims (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id        TEXT NOT NULL,
  request_id    TEXT NOT NULL,
  precedent_ids TEXT NOT NULL,
  claimed_at    TEXT NOT NULL,
  state         TEXT NOT NULL DEFAULT 'claimed' CHECK (state IN ('claimed', 'landed', 'not_landed')),
  closed_at     TEXT,
  core_said     TEXT,
  UNIQUE (run_id, request_id)
);
CREATE INDEX IF NOT EXISTS precedent_claims_state ON precedent_claims(state);
CREATE INDEX IF NOT EXISTS precedent_claims_req ON precedent_claims(request_id);
"""

# An open claim core does not show as landed is closed `not_landed` only once it is this old. The
# read is a replica and the claim is written before the write starts, so a young claim with no
# approval in core is a write still on its way, not one that failed.
NOT_LANDED_AFTER_S = 900

# Ids per by-id statement (reconcile_approved.CHUNK, and its reason).
CHUNK = reconcile_approved.CHUNK

# The replica cancels a statement at about 60 s. Filtering the whole table on
# `metadata->'approval'->>'via'` does not fit (measured 2026-11-15, twice); 30 days of `updatedAt`
# does not either; 6 hours answers in 8 s. So the all-time read walks `updatedAt` in slices,
# halves a slice the replica cancels, and reads the smallest one by id. An approval sets `updatedAt` and nothing moves it back, so a
# row is never earlier than its approval: a floor before the first approval misses none.
SLICE_HOURS = 6
MIN_SLICE_S = 900
BACKFILL_FLOOR = "2026-10-01T00:00:00Z"

# The deploy-proof stop of the scheduled `reconcile`: present, the pass reads nothing and writes
# nothing (exit 0). It does not stop `claim`: a claim step that refuses would stop the approver
# that waits on it, and that one has its own switch.
KILL_FILE = "/etc/hydra/precedent-ledger.disabled"

EXIT_OK = 0
EXIT_NO_PLAN = 2        # no readable plan or result line: nothing was written
EXIT_LEDGER = reconcile_approved.EXIT_LEDGER
EXIT_CORE_UNREAD = reconcile_approved.EXIT_CORE_UNREAD

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_RUN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:+-]{0,119}$")
_STAMP = "%Y-%m-%dT%H:%M:%SZ"

Query = Callable[[str], "list[list[str]]"]


class NoPlan(ValueError):
    """The input carries no plan line this module will act on."""


class CoreRow(NamedTuple):
    status: str
    deleted: bool
    via: str
    run: str
    at: str          # core's approval.at as the ledger writes a time, or '' when it cannot be read
    sets: int        # how many precedent sets core recorded on the row; -1 when it recorded no list
    own: tuple[str, ...]   # the request's own precedent ids, known from core only when sets == 1

    @property
    def approved(self) -> bool:
        """Core holds a precedent approval of this request now."""
        return self.via == VIA and self.status == "approved" and not self.deleted


def run_id_of(row: CoreRow) -> str:
    """The run id this approval's ledger rows carry, or '' when none can be told: no approval time
    to date it by, or a run name that is not one."""
    if not row.at:
        return ""
    if not row.run:
        return UNNAMED_RUN + row.at
    return row.run if _RUN.match(row.run) else ""


def _now(now: float | None) -> float:
    return time.time() if now is None else now


def _stamp(epoch: float) -> str:
    return time.strftime(_STAMP, time.gmtime(epoch))


def _epoch(stamp: str) -> float:
    return datetime.strptime(stamp, _STAMP).replace(tzinfo=timezone.utc).timestamp()


def ledger_time(core_at: str) -> str:
    """Core's `approval.at` ('2026-11-15T07:36:55.643006+00:00') in the ledger's own format, or ''
    when it is not a time. Ledger readers compare these as text, so the format is not a detail."""
    try:
        at = datetime.fromisoformat(core_at.strip().replace("Z", "+00:00"))
    except ValueError:
        return ""
    if at.tzinfo is None:
        return ""
    return at.astimezone(timezone.utc).strftime(_STAMP)


# ── the plan line ────────────────────────────────────────────────────────────

def parse_plan(text: str) -> dict[str, Any]:
    """The plan line in `text`: the bare line, or a program's whole stdout (the last one wins).

    {"marker": "PREV2_PLAN", "run": "<run>", "batch": [{"id": "<request>", "precedent_ids": [...]}]}

    Everything is checked before anything is claimed; a line that fails a check raises NoPlan."""
    found = None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{") or PLAN_MARKER not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError as exc:
            raise NoPlan(f"a {PLAN_MARKER} line is not JSON: {exc}") from exc
        if isinstance(obj, dict) and obj.get("marker") == PLAN_MARKER:
            found = obj
    if found is None:
        raise NoPlan(f"no {PLAN_MARKER} line in the input")
    run, batch = found.get("run"), found.get("batch")
    if not isinstance(run, str) or not _RUN.match(run):
        raise NoPlan("the plan line names no run this can use")
    if not isinstance(batch, list):
        raise NoPlan("batch is not a list")
    out: list[tuple[str, list[str]]] = []
    seen: set[str] = set()
    for item in batch:
        rid = item.get("id") if isinstance(item, dict) else None
        prec = item.get("precedent_ids") if isinstance(item, dict) else None
        if not isinstance(rid, str) or not _UUID.match(rid):
            raise NoPlan(f"a batch entry names no request id: {item!r:.120}")
        if rid in seen:
            raise NoPlan(f"the batch repeats {rid}")
        if (not isinstance(prec, list) or not prec
                or any(not isinstance(p, str) or not _UUID.match(p) for p in prec)):
            raise NoPlan(f"{rid} carries no precedent ids this can use")
        seen.add(rid)
        out.append((rid, list(prec)))
    return {"run": run, "batch": out}


# ── the ledger ───────────────────────────────────────────────────────────────

def open_ledger(path: str, *, write: bool = True) -> ledger_open.LedgerConnection:
    """The credit-review ledger: the request-state tables AND the decision tables. Never created
    here. A write open adds this module's own claims table; a read open adds nothing."""
    db = reconcile_approved.open_ledger(path, write=write)
    have = _tables(db)
    missing = [t for t in ("decisions", "decision_outcomes") if t not in have]
    if missing:
        db.close()
        raise LedgerRefused(f"{path} has no {' or '.join(missing)} table")
    if write:
        db.executescript(CLAIMS_DDL)
    return db


def _tables(db: Any) -> set[str]:
    return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def claim(db: Any, run: str, batch: list[tuple[str, list[str]]], *, now: float | None = None) -> dict[str, Any]:
    """Step 1. One claim per request of the batch, in one transaction: all of them or none.

    A request already claimed under this run keeps its first claim (its time and its precedent
    ids), so the same plan line can be fed twice."""
    at = _stamp(_now(now))
    claimed = 0
    db.execute("BEGIN IMMEDIATE")
    try:
        for rid, prec in batch:
            cur = db.execute("INSERT OR IGNORE INTO precedent_claims (run_id, request_id, precedent_ids, claimed_at) "
                             "VALUES (?,?,?,?)", (run, rid, json.dumps(prec), at))
            claimed += cur.rowcount
        db.commit()
    except BaseException:
        db.rollback()
        raise
    return {"run": run, "offered": len(batch), "claimed": claimed, "already": len(batch) - claimed}


def has_approval(db: Any, rid: str, run: str) -> bool:
    """This request's precedent approval under `run` is in the ledger: its decision row AND its
    `approved` outcome. The one test of "already present", for a live row and a backfilled one."""
    return bool(db.execute(
        "SELECT 1 FROM decisions d JOIN decision_outcomes o ON o.request_id = d.request_id AND o.run_id = d.run_id "
        "WHERE d.request_id = ? AND d.run_id = ? AND d.evidence_kind = ? AND d.decision = 'approve' "
        "AND d.mode = 'apply' AND o.action = 'approve' AND o.outcome = 'approved' LIMIT 1",
        (rid, run, DECISION_PATH)).fetchone())


def backfill_mark(batch: str) -> str:
    """What ends the reason of a row the backfill wrote. A live row never ends with it."""
    return f" [backfill {batch}]"


def reason_for(run: str, row: CoreRow, claimed: list[str] | None) -> str:
    head = f"{VIA} run {run}: " if row.run else f"{VIA}, core recorded no run name (metadata.approval.run): "
    if claimed:
        return head + f"matched {len(claimed)} approved request(s) of the same user: " + ",".join(claimed)
    if row.sets == 1 and row.own:
        return head + f"matched {len(row.own)} approved request(s) of the same user: " + ",".join(row.own)
    if row.sets > 1:
        return head + (f"core recorded the {row.sets} precedent sets of this request's batch and not which one "
                       "is this request's (metadata.approval.precedent_ids)")
    return head + "core recorded no precedent ids for this request (metadata.approval.precedent_ids)"


def write_approval(db: Any, rid: str, run: str, row: CoreRow, *, claimed: list[str] | None = None,
                   mark: str = "", actor: str = ACTOR) -> bool:
    """One approval core holds, written whole: the decision row, its `approved` outcome and the
    move to APPROVED. Inside the caller's transaction; commits nothing. False when the ledger
    already holds this approval, in which case no row is written."""
    if has_approval(db, rid, run):
        return False
    have_decision = db.execute(
        "SELECT 1 FROM decisions WHERE request_id = ? AND run_id = ? AND evidence_kind = ? AND decision = 'approve' "
        "AND mode = 'apply' LIMIT 1", (rid, run, DECISION_PATH)).fetchone()
    if not have_decision:
        # big_track 0: prev2.js takes no request at popularity 60 or more, the decider's big-track line.
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, big_track, decision, reason, "
                   "evidence_kind, mode) VALUES (?,?,?,0,'approve',?,?,'apply')",
                   (run, row.at, rid, reason_for(run, row, claimed) + mark, DECISION_PATH))
    db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) "
               "VALUES (?,?,?,'approve','approved')", (run, row.at, rid))
    request_state.transition(db, rid, TERMINAL, reason=f"{VIA} run {run}", actor=actor)
    return True


# ── core, read-only ──────────────────────────────────────────────────────────

def replica(sql: str) -> list[list[str]]:
    """One read-only statement on the core replica, through the one Trino client the credit code has."""
    from credit_review import verify_notify  # noqa: PLC0415 - claim needs no replica

    return verify_notify.trino(sql)


_COLUMNS = ("id", "status", "deleted", "via", "run", "at", "sets", "own")
_IDS = "jsonb_typeof(metadata->'approval'->'precedent_ids') = 'array'"
_LEN = "jsonb_array_length(metadata->'approval'->'precedent_ids')"
# Postgres' own statement. It extracts in Postgres so that a row's metadata never crosses the
# wire: a batch of n requests holds n precedent sets on each of its n rows.
_PG_SELECT = (
    'SELECT id::text AS id, status::text AS status, ("deletedAt" IS NOT NULL)::text AS deleted, '
    "coalesce(metadata->'approval'->>'via', '') AS via, coalesce(metadata->'approval'->>'run', '') AS run, "
    "coalesce(metadata->'approval'->>'at', '') AS at, "
    f"(CASE WHEN {_IDS} THEN {_LEN} ELSE -1 END)::text AS sets, "
    f"CASE WHEN {_IDS} AND {_LEN} = 1 THEN (metadata->'approval'->'precedent_ids'->0)::text ELSE '' END AS own "
    "FROM public.credit_requests WHERE ")


def passthrough(pg_where: str) -> str:
    """The statement Trino runs: `pg_where` in Postgres, verbatim, through the connector's
    passthrough (owing_proof.STATUS_GUARD_SQL and cs_proof_feed/replica are the precedent). It
    accepts a SELECT only, and the connector's user is the replica's read-only role."""
    return ("SELECT " + ", ".join(_COLUMNS) + " FROM TABLE(postgresql_core.system.query(query => '"
            + (_PG_SELECT + pg_where).replace("'", "''") + "'))")


def by_id_sql(ids: list[str]) -> str:
    bad = [i for i in ids if not _UUID.match(i)]
    if bad:
        raise ValueError(f"not a request id: {bad[0]!r}")
    return passthrough("id IN (" + ", ".join(f"'{i}'::uuid" for i in ids) + ")")


def window_sql(start: str, end: str | None) -> str:
    """Core's precedent approvals whose row changed in [start, end). The time test is written
    first: it is the cheap one, and it is what keeps the statement inside the replica's limit."""
    for stamp in (start, end):
        if stamp is not None:
            _epoch(stamp)   # raises on anything that is not a time: it is about to be text in a statement
    upper = f""" AND "updatedAt" < '{end}'::timestamptz""" if end else ""
    return passthrough(f""""updatedAt" >= '{start}'::timestamptz{upper} """
                       f"AND metadata->'approval'->>'via' = '{VIA}'")


def _core_row(row: list[str], where: str) -> tuple[str, CoreRow]:
    if (len(row) != len(_COLUMNS) or not _UUID.match(row[0]) or not row[1] or row[2] not in ("true", "false")
            or not re.fullmatch(r"-?\d+", row[6])):
        raise CoreUnread(f"{where}: a row this cannot read: {row!r:.200}")
    own: tuple[str, ...] = ()
    if row[7]:
        try:
            got = json.loads(row[7])
        except ValueError:
            got = None
        if isinstance(got, list) and got and all(isinstance(p, str) and _UUID.match(p) for p in got):
            own = tuple(got)
    return row[0], CoreRow(status=row[1], deleted=row[2] == "true", via=row[3], run=row[4],
                           at=ledger_time(row[5]), sets=int(row[6]), own=own)


def ids_changed_sql(start: str, end: str | None) -> str:
    """The ids of every request whose row changed in [start, end). It reads no metadata, so it
    answers where the window statement does not."""
    for stamp in (start, end):
        if stamp is not None:
            _epoch(stamp)
    upper = f""" AND "updatedAt" < '{end}'::timestamptz""" if end else ""
    pg = f"""SELECT id::text AS id FROM public.credit_requests WHERE "updatedAt" >= '{start}'::timestamptz{upper}"""
    return "SELECT id FROM TABLE(postgresql_core.system.query(query => '" + pg.replace("'", "''") + "'))"


def _core_chunk(chunk: list[str], query: Query, where: str) -> dict[str, CoreRow]:
    """One by-id statement. A chunk the replica does not answer is halved, down to one id: a row
    of a large batch is megabytes of metadata to open, and 250 of them can be past the limit."""
    try:
        rows = query(by_id_sql(chunk))
    except Exception as exc:  # noqa: BLE001 - whatever the client raised, the read did not happen
        if len(chunk) == 1:
            raise CoreUnread(f"{where}: {chunk[0]}: {exc}") from exc
        half = len(chunk) // 2
        return {**_core_chunk(chunk[:half], query, where), **_core_chunk(chunk[half:], query, where)}
    asked = set(chunk)
    out: dict[str, CoreRow] = {}
    for raw in rows:
        rid, row = _core_row(raw, where)
        if rid not in asked or rid in out:
            raise CoreUnread(f"{where}: {rid} was not asked for, or answered twice")
        out[rid] = row
    return out


def core_by_id(ids: list[str], query: Query) -> dict[str, CoreRow]:
    """request id -> what core holds, for the ids core holds. Every chunk must answer with rows
    this can read, or the whole read raises CoreUnread."""
    out: dict[str, CoreRow] = {}
    for at in range(0, len(ids), CHUNK):
        out.update(_core_chunk(ids[at:at + CHUNK], query, f"chunk at {at} of {len(ids)}"))
    return out


def _slice_by_id(query: Query, start: str, end: str | None, where: str) -> dict[str, CoreRow]:
    """A slice the window statement cannot answer at its smallest: list what changed in it, which
    opens no metadata, then ask about those ids."""
    try:
        rows = query(ids_changed_sql(start, end))
    except Exception as exc:  # noqa: BLE001 - whatever the client raised, the read did not happen
        raise CoreUnread(f"{where}: the list of changed ids: {exc}") from exc
    ids = []
    for raw in rows:
        if len(raw) != 1 or not _UUID.match(raw[0]):
            raise CoreUnread(f"{where}: a row this cannot read: {raw!r:.200}")
        ids.append(raw[0])
    return {rid: row for rid, row in core_by_id(sorted(set(ids)), query).items() if row.via == VIA}


def core_since(query: Query, start: str, *, now: float | None = None) -> dict[str, CoreRow]:
    """Every precedent approval core holds on a row changed since `start`, by slices of
    `updatedAt`. The last slice has no upper bound, so a row that changes during the walk is
    still read (twice, and the later read wins). A slice the replica does not answer is halved;
    at MIN_SLICE_S it is read by id instead (one UPDATE gives every row of its batch the same
    `updatedAt`, so no smaller slice separates them). A slice neither way answers raises
    CoreUnread, and so nothing is written from a walk that skipped a slice."""
    out: dict[str, CoreRow] = {}
    end_of_walk = _now(now)
    todo = []
    at = _epoch(start)
    while at < end_of_walk:
        todo.append((at, min(at + SLICE_HOURS * 3600, end_of_walk)))
        at += SLICE_HOURS * 3600
    if not todo:
        todo = [(_epoch(start), end_of_walk)]
    while todo:
        a, b = todo.pop(0)
        last = not todo and b >= end_of_walk
        where = f"slice {_stamp(a)} to {'now' if last else _stamp(b)}"
        try:
            rows = query(window_sql(_stamp(a), None if last else _stamp(b)))
        except Exception:  # noqa: BLE001 - whatever the client raised, this statement did not answer
            if b - a > MIN_SLICE_S:
                mid = a + (b - a) // 2
                todo[:0] = [(a, mid), (mid, b)]
            else:
                out.update(_slice_by_id(query, _stamp(a), None if last else _stamp(b), where))
            continue
        for raw in rows:
            rid, row = _core_row(raw, where)
            if row.via != VIA:
                raise CoreUnread(f"{where}: {rid} is not a {VIA} approval")
            out[rid] = row
    return out


# ── reconcile ────────────────────────────────────────────────────────────────

def open_claims(db: Any) -> list[tuple[int, str, str, list[str], str]]:
    return [(cid, run, rid, json.loads(prec), at) for cid, run, rid, prec, at in db.execute(
        "SELECT id, run_id, request_id, precedent_ids, claimed_at FROM precedent_claims "
        "WHERE state = 'claimed' ORDER BY id")]


def _claimed_precedent(db: Any, rid: str, run: str) -> list[str] | None:
    if "precedent_claims" not in _tables(db):   # a read open of a ledger no write open has touched
        return None
    got = db.execute("SELECT precedent_ids FROM precedent_claims WHERE request_id = ? AND run_id = ?",
                     (rid, run)).fetchone()
    return json.loads(got[0]) if got else None


def _why_not(row: CoreRow | None, run: str) -> str:
    """What core said about a claim whose approval it does not hold. Kept on the closed claim."""
    if row is None:
        return "core holds no such request"
    if row.deleted:
        return f"deleted in core (status {row.status})"
    if row.via == VIA and row.run and row.run != run:
        return f"status {row.status}; core's precedent approval is run {row.run}, not this one"
    return f"status {row.status}" + (f", approval via {row.via}" if row.via else ", no approval recorded")


def reconcile(db: Any, query: Query, *, result_ids: list[str] | None = None, since_hours: int | None = None,
              now: float | None = None) -> dict[str, Any]:
    """Step 3. Close every open claim against core, and write the approval of every request core
    holds as precedent-approved among: the open claims, `result_ids`, and (with `since_hours`)
    the rows core changed in that window.

    Core is read whole BEFORE the first write; a read that fails raises CoreUnread and writes
    nothing. Then one SQLite transaction: every claim that closes and every row it implies, or
    none. A claim core does not show as landed stays open until NOT_LANDED_AFTER_S. A claim
    closed `not_landed` whose approval core shows later (a replica that far behind) is closed
    `landed` then: a claim's state is what core last said, and the approval gets its row either
    way."""
    clock = _now(now)
    claims = open_claims(db)
    ids = sorted({rid for _, _, rid, _, _ in claims} | set(result_ids or []))
    core = core_by_id(ids, query) if ids else {}
    if since_hours is not None:
        swept = core_since(query, _stamp(clock - since_hours * 3600), now=clock)
        core = {**swept, **core}     # the by-id read is the later one of a request both name
    else:
        swept = {}
    out = {"claims_open": len(claims), "landed": 0, "not_landed": 0, "still_open": 0, "landed_late": 0,
           "approvals_written": 0, "approvals_already": 0, "unreadable_in_core": 0,
           "result_ids": len(result_ids or []), "result_ids_not_approved_in_core": 0,
           "swept": len(swept)}
    closed_at = _stamp(clock)
    db.execute("BEGIN IMMEDIATE")
    try:
        for rid in sorted(core):
            row = core[rid]
            if not row.approved:
                continue
            run = run_id_of(row)
            if not run:
                out["unreadable_in_core"] += 1   # an approval with no time, or a run name that is not one
                continue
            wrote = write_approval(db, rid, run, row, claimed=_claimed_precedent(db, rid, run))
            out["approvals_written" if wrote else "approvals_already"] += 1
            out["landed_late"] += db.execute(
                "UPDATE precedent_claims SET state = 'landed', closed_at = ?, core_said = ? "
                "WHERE request_id = ? AND run_id = ? AND state = 'not_landed'",
                (closed_at, f"approved under run {run}, read after this was closed not_landed", rid,
                 run)).rowcount
        for cid, run, rid, _prec, claimed_at in claims:
            row = core.get(rid)
            if row is not None and row.approved and row.run == run:
                if not has_approval(db, rid, run):
                    out["still_open"] += 1   # core holds it and its row was not writable: unreadable_in_core
                    continue
                db.execute("UPDATE precedent_claims SET state = 'landed', closed_at = ?, core_said = ? "
                           "WHERE id = ? AND state = 'claimed'", (closed_at, f"approved under run {run}", cid))
                out["landed"] += 1
            elif clock - _epoch(claimed_at) >= NOT_LANDED_AFTER_S:
                db.execute("UPDATE precedent_claims SET state = 'not_landed', closed_at = ?, core_said = ? "
                           "WHERE id = ? AND state = 'claimed'", (closed_at, _why_not(row, run), cid))
                out["not_landed"] += 1
            else:
                out["still_open"] += 1
        db.commit()
    except BaseException:
        db.rollback()
        raise
    out["result_ids_not_approved_in_core"] = sum(
        1 for rid in (result_ids or []) if rid not in core or not core[rid].approved)
    return out


# ── backfill ─────────────────────────────────────────────────────────────────

def plan_backfill(db: Any, core: dict[str, CoreRow]) -> dict[str, Any]:
    """Every precedent approval core returned, in exactly one class, so the classes add up to
    `core_precedent_approvals`. Only `missing` is written.

    `not_approved_now` and `deleted` are approvals core recorded and no longer holds (taken back,
    or the row deleted). They get no row: the request is live again in the queues, and a new
    newest `approve` row would sit over the hold or the partial approval it is under."""
    classes = {"missing": 0, "already_present": 0, "not_approved_now": 0, "deleted": 0, "unreadable_approval": 0}
    todo: list[tuple[str, str, CoreRow]] = []
    unnamed = 0
    for rid in sorted(core):
        row = core[rid]
        run = run_id_of(row)
        if row.deleted:
            cls = "deleted"
        elif row.status != "approved":
            cls = "not_approved_now"
        elif not run:
            cls = "unreadable_approval"
        elif has_approval(db, rid, run):
            cls = "already_present"
        else:
            cls = "missing"
            todo.append((rid, run, row))
            unnamed += not row.run
        classes[cls] += 1
    return {"core_precedent_approvals": len(core), **classes, "missing_with_no_run_name": unnamed, "todo": todo}


def backfill(path: str, *, apply: bool, batch: str | None = None, query: Query = replica,
             floor: str = BACKFILL_FLOOR, now: float | None = None) -> dict[str, Any]:
    """Plan, and with `apply` insert. The whole core read finishes before the first write, and
    the inserts are one transaction. An empty answer is an unread one: core holds approvals."""
    clock = _now(now)
    batch = batch or "precedent-backfill-" + time.strftime("%Y-%m-%dT%H%MZ", time.gmtime(clock))
    if not _RUN.match(batch):
        raise ValueError(f"not a batch id: {batch!r}")
    db = open_ledger(path, write=apply)
    try:
        core = core_since(query, floor, now=clock)
        if not core:
            raise CoreUnread(f"core answered no {VIA} approval since {floor}")
        plan = plan_backfill(db, core)
        todo = plan.pop("todo")
        out = {"mode": "applied" if apply else "plan", "batch": batch, "floor": floor, **plan, "inserted": 0}
        if apply:
            db.execute("BEGIN IMMEDIATE")
            try:
                for rid, run, row in todo:
                    out["inserted"] += write_approval(db, rid, run, row, claimed=_claimed_precedent(db, rid, run),
                                                      mark=backfill_mark(batch), actor=BACKFILL_ACTOR)
                db.commit()
            except BaseException:
                db.rollback()
                raise
        return out
    finally:
        db.close()


# ── report ───────────────────────────────────────────────────────────────────

def report(path: str) -> dict[str, Any]:
    """What this module wrote and what is open. Reads only; a ledger no write open has touched
    has no claims table, which reads as no claim."""
    db = open_ledger(path, write=False)
    try:
        rows = db.execute(
            "SELECT d.reason FROM decisions d JOIN decision_outcomes o ON o.request_id = d.request_id "
            "AND o.run_id = d.run_id WHERE d.evidence_kind = ? AND d.decision = 'approve' AND d.mode = 'apply' "
            "AND o.action = 'approve' AND o.outcome = 'approved'", (DECISION_PATH,)).fetchall()
        batches: dict[str, int] = {}
        live = 0
        for (reason,) in rows:
            found = re.search(r" \[backfill ([^\]]+)\]$", reason or "")
            if found:
                batches[found.group(1)] = batches.get(found.group(1), 0) + 1
            else:
                live += 1
        claims: dict[str, int] = {}
        oldest = None
        if "precedent_claims" in _tables(db):
            claims = {s: n for s, n in db.execute("SELECT state, count(*) FROM precedent_claims GROUP BY state")}
            oldest = db.execute("SELECT min(claimed_at) FROM precedent_claims WHERE state = 'claimed'").fetchone()[0]
        return {"precedent_approvals": len(rows), "live": live, "backfilled": dict(sorted(batches.items())),
                "claims": dict(sorted(claims.items())), "oldest_open_claim": oldest}
    finally:
        db.close()


# ── entrypoint ───────────────────────────────────────────────────────────────

def _text(arg: str | None) -> str:
    return sys.stdin.read() if arg in (None, "-") else arg


def _fail(exc: BaseException, wrote: str) -> int:
    if isinstance(exc, CoreUnread):
        print(f"precedent_ledger: core was not read ({exc}); {wrote}", file=sys.stderr)
        return EXIT_CORE_UNREAD
    print(f"precedent_ledger: {exc}; {wrote}", file=sys.stderr)
    return EXIT_NO_PLAN if isinstance(exc, (NoPlan, reconcile_approved.NoResult)) else EXIT_LEDGER


_REFUSALS = (NoPlan, reconcile_approved.NoResult, CoreUnread, LedgerRefused, ledger_open.LedgerNotWritableError)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("claim", help="step 1: the plan line, before the core write")
    one.add_argument("plan", nargs="?", help="the PREV2_PLAN line; read from stdin when absent or '-'")
    two = sub.add_parser("reconcile", help="step 3: close open claims against core")
    two.add_argument("--result", nargs="?", const="-", help="a PREV2_RESULT line (or '-' for stdin): its ids too")
    two.add_argument("--since-hours", type=int, help="also every precedent approval core changed in this window")
    three = sub.add_parser("backfill", help="every precedent approval core holds that has no row here")
    three.add_argument("--apply", action="store_true", help="insert them; without it only the plan is printed")
    three.add_argument("--batch", help="the batch id the inserted rows carry (default: precedent-backfill-<now>)")
    four = sub.add_parser("report", help="what this module wrote and what is open")
    for p in (one, two, three, four):
        p.add_argument("--ledger", default=LEDGER)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "claim":
            plan = parse_plan(_text(args.plan))
            db = open_ledger(args.ledger)
            try:
                out = claim(db, plan["run"], plan["batch"])
            finally:
                db.close()
        elif args.cmd == "reconcile":
            if args.since_hours is not None and not 1 <= args.since_hours <= 72:
                ap.error("--since-hours is 1 to 72; `backfill` reads further back")
            if os.path.exists(os.environ.get("PRECEDENT_LEDGER_KILL_FILE", KILL_FILE)):
                print(json.dumps({"skipped": "kill_file"}))
                return EXIT_OK
            ids = reconcile_approved.parse_result(_text(args.result))["ids"] if args.result else None
            db = open_ledger(args.ledger)
            try:
                out = reconcile(db, replica, result_ids=ids, since_hours=args.since_hours)
            finally:
                db.close()
        elif args.cmd == "backfill":
            out = backfill(args.ledger, apply=args.apply, batch=args.batch)
        else:
            out = report(args.ledger)
    except _REFUSALS as exc:
        return _fail(exc, "nothing was written")
    print(json.dumps(out, sort_keys=True))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
