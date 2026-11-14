#!/usr/bin/env python3
"""Move the requests precedent_v1 approved in core to APPROVED in the node-8 request ledger.

precedent_v1 (prev2.js) runs inside a core-backend-api pod and writes `credit_requests` in core's
Postgres. The undecided count is read from `request_state`, a SQLite table on node-8 that the pod
cannot reach, so an approval never left that count. This reads the one line prev2.js prints for a
program (`{"marker":"PREV2_RESULT",...}`, the ids approved under its run name, read after COMMIT)
and records each id through `request_state.transition()`.

NOTHING RUNS THE RECURRING STEP YET. When this file landed, prev2.js was not in this repository
(the copy node-8 runs is /root/prev2.js; a tracked one is https://github.com/Muso-AI/hydra/pull/1967)
and no prev2.js printed the result line (https://github.com/Muso-AI/hydra/pull/1968 adds it). The
service command that pipes one into the other needs both and is not here either. Until it is, the
only way a request reaches APPROVED is `backfill --apply`, run by a person.

THIS IS THE FIRST WRITER OF `APPROVED`. Read this before assuming the state has a history:

  * `APPROVED` was declared in a docstring only (request_state.py, "approved (by proof, precedent,
    or validator)"). Before this module no code wrote it: on 2026-11-14 `request_state` and
    `request_state_log` held 0 rows with it, 104,576 log rows in all.
  * Nothing enforces the state list. There is no list of states in code and no CHECK on either
    table: `transition()` accepts any string. The name is right here because TERMINAL below says
    so, and for no other reason.

Which transition(): request_state.py's, never the second body in the untracked decider.py on
node-8. That one is UPDATE-only, so for a request with no `request_state` row it changes nothing,
still appends a log row, and does so again on every rerun. request_state.py's inserts the row, and
returns False without writing when the request is already in the state. That return is the whole
of this module's idempotency: the same line can be fed twice.

One transaction: every id is moved or none is. A line that cannot be read, or a ledger that is not
the one expected, moves nothing and exits non-zero.

Three uses:

  reconcile_approved.py [LINE]      the recurring step: LINE, or stdin, carries the result line.
                                    `--echo` copies stdin through to stdout as it arrives, so a
                                    journal still shows what prev2.js printed. Feed it on stdin:
                                    a full hour's line is past the 128 KB one argument may be.
  reconcile_approved.py backfill    the requests the ledger still counts as undecided that core
                                    has approved, by any approver. Prints the plan and writes
                                    nothing; `--apply` moves them. Run it again whenever: a moved
                                    request is not offered twice.
  reconcile_approved.py measure     the undecided count from core's credit_requests.status and
                                    from request_state, side by side. Reads only.

The recurring step reads no core table. `backfill` and `measure` read the replica and never write
core. Nothing here decides a request. Stdlib only.
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

_SCRIPTS = Path(__file__).resolve().parents[1]
if str(_SCRIPTS) not in sys.path:  # run as a file (`python3 reconcile_approved.py`), not only as a package
    sys.path.insert(0, str(_SCRIPTS))

from credit_review import ledger_open, request_state  # noqa: E402 - after the path line above

# The same file, and the same override, as verify_ledger.DEFAULT_PATH.
LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
MARKER = "PREV2_RESULT"
TERMINAL = "APPROVED"   # request_state.py's docstring; see the module docstring before trusting it
ACTOR = "prev2"
TABLES = ("request_state", "request_state_log")

BACKFILL_ACTOR = "reconcile-backfill"

# The states the firstmate checker counts as undecided (state/verif-pipeline.check.sh, B1). The
# checker is outside this repository, so no test can hold the two together: change one, change both.
UNDECIDED = ("ASKED", "OPEN_UNASKED", "PROOF_RECEIVED")
# Core has two decided statuses. Every other status of a request that is not deleted is undecided.
CORE_DECIDED = ("approved", "rejected")

# Ids per by-id statement. Trino sends Postgres an IN list of up to 256 values as it is; from 257
# it sends the range between the smallest and the largest instead, and for ids spread over the
# table that is a full scan: measured 2026-11-14, 256 ids answered in 3.6 s and 257 ended in
# "canceling statement due to statement timeout". (Each statement costs about 2 s before it reads
# a row, which is why the backfill does not ask about every id: see plan_backfill.)
CHUNK = 250

EXIT_OK = 0
EXIT_NO_RESULT = 2      # no readable result line: nothing was moved
EXIT_LEDGER = 3         # the ledger is missing, is not the request ledger, or refused the write
EXIT_CORE_UNREAD = 4    # the replica did not answer, or answered something this cannot use

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class NoResult(ValueError):
    """The input carries no result line this module will act on."""


class LedgerRefused(RuntimeError):
    """The ledger is not there, or is not the request ledger."""


class CoreUnread(RuntimeError):
    """The replica gave no answer this module can use. Never the same as "nothing to do"."""


def parse_result(text: str) -> dict[str, Any]:
    """The PREV2_RESULT line in `text`: the bare line, or prev2.js's whole stdout (the last one wins).

    Every field this module acts on is checked before anything is written. A line that fails a
    check raises NoResult: half a list is never moved."""
    found = None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{") or MARKER not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError as exc:
            raise NoResult(f"a {MARKER} line is not JSON: {exc}") from exc
        if isinstance(obj, dict) and obj.get("marker") == MARKER:
            found = obj
    if found is None:
        raise NoResult(f"no {MARKER} line in the input")
    run, ids, count = found.get("run"), found.get("approved_ids"), found.get("approved")
    if not isinstance(run, str) or not run.strip():
        raise NoResult("the result line names no run")
    if not isinstance(ids, list):
        raise NoResult("approved_ids is not a list")
    bad = [i for i in ids if not isinstance(i, str) or not _UUID.match(i)]
    if bad:
        raise NoResult(f"{len(bad)} of {len(ids)} approved_ids are not request ids (first: {bad[0]!r})")
    if len(set(ids)) != len(ids):
        raise NoResult("approved_ids repeats an id")
    if isinstance(count, bool) or not isinstance(count, int) or count != len(ids):
        raise NoResult(f"approved says {count!r} and approved_ids holds {len(ids)}")
    return {"run": run.strip(), "ids": ids}


def open_ledger(path: str, *, write: bool = True) -> ledger_open.LedgerConnection:
    """The request ledger. Never created here: a path with no ledger, or a file without both
    tables, is refused, so a wrong path cannot grow an empty ledger that counts as success."""
    if not os.path.isfile(path):
        raise LedgerRefused(f"{path} does not exist")
    if write:
        db = ledger_open.open_rw(path, opener="reconcile_approved", timeout=60)
        db.execute("PRAGMA busy_timeout=60000")
    else:
        db = ledger_open.open_ro(path, opener="reconcile_approved", timeout=60)
    have = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    missing = [t for t in TABLES if t not in have]
    if missing:
        db.close()
        raise LedgerRefused(f"{path} has no {' or '.join(missing)} table")
    return db


def move(db: Any, offers: list[tuple[str, str]], actor: str) -> dict[str, Any]:
    """Offer every (request id, reason) to transition() in one transaction: all of them or none.

    `moved_from` is where the moved requests stood, read inside the transaction. `no_row` is a
    request the ledger had never held: transition() inserts it."""
    moved_from: dict[str, int] = {}
    db.execute("BEGIN IMMEDIATE")
    try:
        for rid, reason in offers:
            row = db.execute("SELECT state FROM request_state WHERE request_id=?", (rid,)).fetchone()
            if request_state.transition(db, rid, TERMINAL, reason=reason, actor=actor):
                frm = row[0] if row else "no_row"
                moved_from[frm] = moved_from.get(frm, 0) + 1
        db.commit()
    except BaseException:
        db.rollback()
        raise
    moved = sum(moved_from.values())
    return {"moved": moved, "offered": len(offers), "already": len(offers) - moved,
            "moved_from": dict(sorted(moved_from.items()))}


def reconcile(db: Any, ids: list[str], run: str) -> dict[str, Any]:
    """The recurring step: the ids one result line carries."""
    return {**move(db, [(rid, f"precedent_v1 run {run}") for rid in ids], ACTOR), "run": run}


# ── the replica ──────────────────────────────────────────────────────────────

def replica(sql: str) -> list[list[str]]:
    """One read-only statement on the core replica, through the one Trino client the credit code has."""
    from credit_review import verify_notify  # noqa: PLC0415 - only backfill and measure need it

    return verify_notify.trino(sql)


def status_sql(ids: list[str]) -> str:
    """Core's status of these requests. Every id is checked to be a request id before it is text."""
    bad = [i for i in ids if not _UUID.match(i)]
    if bad:
        raise ValueError(f"not a request id: {bad[0]!r}")
    return ("SELECT CAST(id AS varchar), status, CAST(deletedat IS NOT NULL AS varchar), "
            "coalesce(json_extract_scalar(CAST(metadata AS json), '$.approval.via'), '') "
            "FROM postgresql_core.public.credit_requests WHERE id IN ("
            + ", ".join(f"UUID '{i}'" for i in ids) + ")")


CORE_COUNT_SQL = ("SELECT status, count(*) FROM postgresql_core.public.credit_requests "
                  "WHERE deletedat IS NULL GROUP BY status")


CORE_UNDECIDED_SQL = ("SELECT CAST(id AS varchar), status, CAST(deletedat IS NOT NULL AS varchar), '' "
                      "FROM postgresql_core.public.credit_requests "
                      "WHERE status NOT IN ('approved', 'rejected')")


def core_undecided(query: Any) -> dict[str, tuple[str, bool, str]]:
    """request id -> (status, deleted, ''), for every request core has not decided, deleted ones
    included. One read. An empty answer is an unread one: core always holds undecided requests."""
    try:
        rows = query(CORE_UNDECIDED_SQL)
    except Exception as exc:  # noqa: BLE001 - whatever the client raised, the read did not happen
        raise CoreUnread(f"the undecided read: {exc}") from exc
    if not rows:
        raise CoreUnread("the undecided read: core answered no undecided request")
    out: dict[str, tuple[str, bool, str]] = {}
    for row in rows:
        if (len(row) != 4 or not _UUID.match(row[0]) or row[0] in out or not row[1]
                or row[1] in CORE_DECIDED or row[2] not in ("true", "false")):
            raise CoreUnread(f"the undecided read: a row this cannot read: {row!r}")
        out[row[0]] = (row[1], row[2] == "true", "")
    return out


def core_status(ids: list[str], query: Any) -> dict[str, tuple[str, bool, str]]:
    """request id -> (status, deleted, approval via), for the ids core holds. Every chunk must
    answer, with rows this can read, or the whole read raises CoreUnread."""
    out: dict[str, tuple[str, bool, str]] = {}
    for at in range(0, len(ids), CHUNK):
        chunk = ids[at:at + CHUNK]
        try:
            rows = query(status_sql(chunk))
        except Exception as exc:  # noqa: BLE001 - whatever the client raised, the read did not happen
            raise CoreUnread(f"chunk at {at} of {len(ids)}: {exc}") from exc
        asked = set(chunk)
        for row in rows:
            if len(row) != 4 or row[0] not in asked or row[2] not in ("true", "false") or not row[1]:
                raise CoreUnread(f"chunk at {at} of {len(ids)}: a row this cannot read: {row!r}")
            if row[0] in out:
                raise CoreUnread(f"chunk at {at} of {len(ids)}: {row[0]} answered twice")
            out[row[0]] = (row[1], row[2] == "true", row[3])
    return out


# ── backfill ─────────────────────────────────────────────────────────────────

def plan_backfill(db: Any, query: Any) -> dict[str, Any]:
    """What core says about every request the ledger counts as undecided.

    `core` sorts each of them into one class, so the classes add up to `asked`. Only `approved`
    (approved and not deleted) is moved. The others stay counted and are named, never dropped.

    Two reads, and every class rests on a row core returned. First, one read of every request core
    has not decided: most of the ledger's undecided requests are in it. Then only the rest are
    asked about by id (`asked_by_id`), CHUNK a statement. A request is `approved` only when a
    by-id row says so; a request neither read names is `not_in_core` and is not moved."""
    marks = ",".join("?" for _ in UNDECIDED)
    held = [r[0] for r in db.execute(
        f"SELECT request_id FROM request_state WHERE state IN ({marks}) ORDER BY request_id", UNDECIDED)]
    ids = [i for i in held if _UUID.match(i)]
    undecided = core_undecided(query)
    rest = [i for i in ids if i not in undecided]
    core = {**{i: undecided[i] for i in ids if i in undecided}, **core_status(rest, query)}
    classes: dict[str, int] = {}
    offers: list[tuple[str, str]] = []
    via_count: dict[str, int] = {}
    for rid in ids:
        if rid not in core:
            cls = "not_in_core"
        else:
            status, deleted, via = core[rid]
            if status == "approved" and deleted:
                # Core's own count leaves a deleted row out (`deletedat IS NULL`), so it is not
                # an approval core still holds. Counted and named here, not moved.
                cls = "approved_and_deleted"
            elif status == "approved":
                cls = "approved"
                via = via or "not recorded"
                via_count[via] = via_count.get(via, 0) + 1
                offers.append((rid, f"backfill: approved in core (via {via})"))
            elif status == "rejected":
                cls = "rejected"
            elif deleted:
                cls = "deleted_while_undecided"
            else:
                cls = "undecided_in_core"
        classes[cls] = classes.get(cls, 0) + 1
    return {"ledger_undecided": len(held), "not_a_credit_request_id": len(held) - len(ids),
            "asked": len(ids), "asked_by_id": len(rest), "core": dict(sorted(classes.items())),
            "approved_via": dict(sorted(via_count.items())), "offers": offers}


def backfill(path: str, *, apply: bool, query: Any = replica) -> dict[str, Any]:
    """Plan, and with `apply` move. The whole replica read finishes before the first write."""
    db = open_ledger(path, write=apply)
    try:
        plan = plan_backfill(db, query)
        offers = plan.pop("offers")
        out = {"mode": "applied" if apply else "plan", **plan, "to_move": len(offers)}
        if apply:
            out.update(move(db, offers, BACKFILL_ACTOR))
        return out
    finally:
        db.close()


# ── measurement ──────────────────────────────────────────────────────────────

def measure(path: str, *, query: Any = replica, now: float | None = None) -> dict[str, Any]:
    """Both undecided counts. A side that could not be read is `None` with its reason, never 0."""
    out: dict[str, Any] = {}
    try:
        db = open_ledger(path, write=False)
        try:
            states = {s: n for s, n in db.execute("SELECT state, count(*) FROM request_state GROUP BY state")}
            last = db.execute("SELECT max(at) FROM request_state_log").fetchone()[0]
        finally:
            db.close()
        out["ledger"] = {"undecided": sum(states.get(s, 0) for s in UNDECIDED),
                         "by_state": dict(sorted(states.items())), "last_transition_at": last,
                         "last_transition_age_h": _age_h(last, now)}
    except (LedgerRefused, sqlite3.Error) as exc:
        out["ledger"] = {"undecided": None, "unread": str(exc)}
    try:
        try:
            rows = query(CORE_COUNT_SQL)
        except Exception as exc:  # noqa: BLE001 - whatever the client raised, the read did not happen
            raise CoreUnread(str(exc)) from exc
        by: dict[str, int] = {}
        for row in rows:
            if len(row) != 2 or not row[0] or not row[1].isdigit() or row[0] in by:
                raise CoreUnread(f"a row this cannot read: {row!r}")
            by[row[0]] = int(row[1])
        if not any(s in by for s in CORE_DECIDED):
            raise CoreUnread(f"no decided status in the answer: {sorted(by)}")
        out["core"] = {"undecided": sum(n for s, n in by.items() if s not in CORE_DECIDED),
                       "by_status": dict(sorted(by.items()))}
    except CoreUnread as exc:
        out["core"] = {"undecided": None, "unread": str(exc)}
    return out


def _age_h(at: str | None, now: float | None) -> float | None:
    if not at:
        return None
    try:
        then = calendar.timegm(time.strptime(at, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None
    return round(((time.time() if now is None else now) - then) / 3600, 2)


def render_measure(m: dict[str, Any]) -> str:
    def side(d: dict[str, Any]) -> str:
        return f"{d['undecided']:,}" if d["undecided"] is not None else f"NOT MEASURED ({d['unread']})"
    lines = ["undecided credit requests",
             f"  core    credit_requests.status   {side(m['core'])}",
             f"  node-8  request_state            {side(m['ledger'])}"]
    if m["core"]["undecided"] is not None:
        lines.append("  core, not deleted, by status: " + ", ".join(
            f"{s} {n:,}" for s, n in m["core"]["by_status"].items()))
    if m["ledger"]["undecided"] is not None:
        lines.append("  request_state by state: " + ", ".join(
            f"{s} {n:,}" for s, n in m["ledger"]["by_state"].items()))
        age = m["ledger"]["last_transition_age_h"]
        lines.append(f"  last transition in request_state_log: {m['ledger']['last_transition_at']}"
                     + (f" ({age} h ago)" if age is not None else ""))
    return "\n".join(lines)


def _read_stdin(echo: bool) -> str:
    if not echo:
        return sys.stdin.read()
    kept = []
    for line in sys.stdin:
        sys.stdout.write(line)
        sys.stdout.flush()
        kept.append(line)
    return "".join(kept)


def _main_backfill(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="reconcile_approved.py backfill")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--apply", action="store_true", help="move them; without it only the plan is printed")
    args = ap.parse_args(argv)
    try:
        out = backfill(args.ledger, apply=args.apply)
    except CoreUnread as exc:
        print(f"reconcile_approved: core was not read ({exc}); nothing was moved", file=sys.stderr)
        return EXIT_CORE_UNREAD
    except (LedgerRefused, ledger_open.LedgerNotWritableError) as exc:
        print(f"reconcile_approved: {exc}; nothing was moved", file=sys.stderr)
        return EXIT_LEDGER
    print(json.dumps(out, sort_keys=True))
    return EXIT_OK


def _main_measure(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="reconcile_approved.py measure")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    m = measure(args.ledger)
    print(json.dumps(m, sort_keys=True) if args.json else render_measure(m))
    if m["ledger"]["undecided"] is None:
        return EXIT_LEDGER
    return EXIT_CORE_UNREAD if m["core"]["undecided"] is None else EXIT_OK


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["backfill"]:
        return _main_backfill(argv[1:])
    if argv[:1] == ["measure"]:
        return _main_measure(argv[1:])
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("result", nargs="?", help="the PREV2_RESULT line; read from stdin when absent or '-'")
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--echo", action="store_true", help="copy stdin through to stdout as it arrives")
    args = ap.parse_args(argv)
    text = _read_stdin(args.echo) if args.result in (None, "-") else args.result
    try:
        got = parse_result(text)
    except NoResult as exc:
        print(f"reconcile_approved: {exc}; nothing was moved", file=sys.stderr)
        return EXIT_NO_RESULT
    try:
        db = open_ledger(args.ledger)
    except LedgerRefused as exc:
        print(f"reconcile_approved: {exc}; nothing was moved", file=sys.stderr)
        return EXIT_LEDGER
    try:
        out = reconcile(db, got["ids"], got["run"])
    except ledger_open.LedgerNotWritableError as exc:
        print(f"reconcile_approved: {exc}; nothing was moved", file=sys.stderr)
        return EXIT_LEDGER
    finally:
        db.close()
    print(json.dumps(out, sort_keys=True))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
