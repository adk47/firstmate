#!/usr/bin/env python3
"""Measure what a ledger writer does under lock contention, for ONE copy of ledger_open.py.

    python3 measure.py --ledger-open scripts/credit_review/ledger_open.py            # this tree
    git show origin/main:scripts/credit_review/ledger_open.py > /tmp/before.py
    python3 measure.py --ledger-open /tmp/before.py                                  # the tree before the change

Run it once per copy and compare the two JSON documents: that is the before/after in report.md.

Every ledger is a scratch file in a fresh temp directory. It takes no path to a real ledger, on purpose, and touches
nothing outside that directory. The other parties to each lock are threads of this process holding their own plain
sqlite3 connections: SQLite arbitrates connections of one process exactly as it does connections of several, so the
waits and the errors are the ones separate jobs would meet. What this cannot show is anything about node-8: its
filesystem, its load, or which statement the intercom drain was on when it died.

Each case answers with what happened, never with a verdict: the error's type and words, and the seconds it took.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable


def load(path: str) -> Any:
    spec = importlib.util.spec_from_file_location("ledger_open_under_measure", path)
    assert spec and spec.loader, path
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module          # @dataclass looks its module up by name
    spec.loader.exec_module(module)
    return module


class Scratch:
    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="lbt-measure-"))
        self.n = 0

    def ledger(self, *, mode: str | None = None) -> str:
        """A new ledger with one table. `mode` None leaves it as SQLite makes a file (rollback journal)."""
        self.n += 1
        path = str(self.dir / f"ledger-{self.n}.sqlite3")
        db = sqlite3.connect(path)
        if mode:
            db.execute(f"PRAGMA journal_mode={mode}").fetchall()
        db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, who TEXT)")
        db.commit()
        db.close()
        return path

    def close(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def outcome(call: Callable[[], Any]) -> dict[str, Any]:
    t0 = time.monotonic()
    try:
        value = call()
    except Exception as exc:  # noqa: BLE001 - the outcome IS the measurement
        return {"ok": False, "seconds": round(time.monotonic() - t0, 2), "error_type": type(exc).__name__,
                "error": " ".join(str(exc).split())[:300]}
    return {"ok": True, "seconds": round(time.monotonic() - t0, 2), "value": value}


def hold(path: str, sql: str, seconds: float, *, started: threading.Event,
         release: str = "ROLLBACK") -> threading.Thread:
    """Another job: opens the ledger, runs `sql` (which takes a lock), keeps it `seconds`, lets go."""
    def run() -> None:
        db = sqlite3.connect(path, timeout=60, isolation_level=None)
        cur = db.execute(sql)
        if sql.lstrip().upper().startswith("SELECT"):
            cur.fetchone()                   # an unfinished SELECT: the read lock stays held
        started.set()
        time.sleep(seconds)
        cur.close()
        if release:
            try:
                db.execute(release)
            except sqlite3.Error:
                pass
        db.close()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    assert started.wait(10), "the lock holder never started"
    return t


def journal_mode(path: str) -> str:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return str(db.execute("PRAGMA journal_mode").fetchall()[0][0])
    finally:
        db.close()


def measure(lo: Any, *, long_hold_s: float) -> dict[str, Any]:
    s = Scratch()
    out: dict[str, Any] = {}
    try:
        # 1. What a connection is given when its caller names no timeout, and what a new ledger's journal mode is.
        path = str(s.dir / "made-by-the-opener.sqlite3")
        db = lo.open_rw(path, opener="measure")
        out["busy_timeout_ms_caller_names_none"] = db.execute("PRAGMA busy_timeout").fetchall()[0][0]
        db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, who TEXT)")
        db.commit()
        db.close()
        out["journal_mode_of_a_ledger_open_rw_created"] = journal_mode(path)

        db = lo.open_rw(s.ledger(), opener="measure", timeout=5)
        out["busy_timeout_ms_caller_names_5s"] = db.execute("PRAGMA busy_timeout").fetchall()[0][0]
        db.close()

        rollback = s.ledger()
        lo.open_rw(rollback, opener="measure", timeout=30).close()
        out["journal_mode_of_a_rollback_ledger_after_open_rw"] = journal_mode(rollback)

        ro = s.ledger()
        r = lo.open_ro(ro, opener="measure")
        out["busy_timeout_ms_reader_names_none"] = r.execute("PRAGMA busy_timeout").fetchall()[0][0]
        r.close()
        out["journal_mode_of_a_rollback_ledger_after_open_ro"] = journal_mode(ro)

        # 2. write_state()'s probe, then the busy timeout the connection is left with.
        db = lo.open_rw(s.ledger(mode="WAL"), opener="measure", timeout=30)
        lo.write_state(db)
        out["busy_timeout_ms_after_write_state"] = db.execute("PRAGMA busy_timeout").fetchall()[0][0]
        db.close()

        # 3. A writer whose caller named no timeout, behind another job holding the write lock for 8 s.
        path = s.ledger(mode="WAL")
        db = lo.open_rw(path, opener="measure", isolation_level=None)
        t = hold(path, "BEGIN IMMEDIATE", 8.0, started=threading.Event())
        out["write_behind_an_8s_writer_caller_names_no_timeout"] = outcome(
            lambda: db.execute("INSERT INTO t (who) VALUES ('w')").rowcount)
        t.join()
        db.close()

        # 4. A writer on a ledger nobody put in WAL, behind a reader that keeps a SELECT open for 3 s.
        #    (Opened first, as a job that starts while another is reading does not exist before it starts.)
        path = s.ledger()
        db = lo.open_rw(path, opener="measure", timeout=30, isolation_level=None)
        t = hold(path, "SELECT * FROM t UNION ALL SELECT 1, 'x' UNION ALL SELECT 2, 'y'", 3.0,
                 started=threading.Event(), release="")
        out["write_behind_a_3s_reader_on_a_ledger_nobody_set_to_wal"] = outcome(
            lambda: db.execute("INSERT INTO t (who) VALUES ('w')").rowcount)
        t.join()
        db.close()

        # 5. A writer with the callers' usual timeout=30, behind another job that keeps the write lock for longer
        #    than that (long_hold_s).
        path = s.ledger(mode="WAL")
        db = lo.open_rw(path, opener="measure", timeout=30, isolation_level=None)
        t = hold(path, "BEGIN IMMEDIATE", long_hold_s, started=threading.Event())
        out[f"write_behind_a_{long_hold_s:g}s_writer_caller_names_30s"] = outcome(
            lambda: db.execute("INSERT INTO t (who) VALUES ('w')").rowcount)
        t.join()
        db.close()

        # 6. A writer that never gets the lock at all: how long until it says so, and what it says.
        path = s.ledger(mode="WAL")
        db = lo.open_rw(path, opener="measure", timeout=30, isolation_level=None)
        db.execute("PRAGMA busy_timeout=300")          # this connection only: the shape, without 90 s of waiting
        t = hold(path, "BEGIN IMMEDIATE", 4.0, started=threading.Event())
        out["write_behind_a_writer_that_outlasts_every_try_busy_timeout_300ms"] = outcome(
            lambda: db.execute("INSERT INTO t (who) VALUES ('w')").rowcount)
        t.join()
        db.close()

        # 7. Not a lock: a constraint error must come back at once, once.
        db = lo.open_rw(s.ledger(mode="WAL"), opener="measure", timeout=30, isolation_level=None)
        db.execute("INSERT INTO t (id, who) VALUES (1, 'a')")
        out["a_constraint_error"] = outcome(lambda: db.execute("INSERT INTO t (id, who) VALUES (1, 'b')").rowcount)
        db.close()
    finally:
        s.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ledger-open", required=True, help="the ledger_open.py to measure")
    ap.add_argument("--long-hold-seconds", type=float, default=36.0,
                    help="how long the other writer of case 5 keeps the lock (default 36: past a 30 s timeout)")
    args = ap.parse_args()
    lo = load(args.ledger_open)
    doc = {"ledger_open": args.ledger_open, "python": sys.version.split()[0], "sqlite": sqlite3.sqlite_version,
           "cases": measure(lo, long_hold_s=args.long_hold_seconds)}
    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
