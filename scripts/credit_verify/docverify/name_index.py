"""A local index of every catalog profile name, for xc_people (proof-loop lead 2026-10-28 075 (2)).

Why: the per-document look-up (`intel.trino_name_index`) scanned all 24.2M `catalog_profile` rows with a
fold expression on EVERY document - 41 s on average on the shared Trino coordinator, 4 of 10 over the
60 s limit (system.runtime.queries, 2026-10-28). One export is the same single scan (38 s measured), so
the index is built from one export at most every TTL_S and every look-up is local.

Shape: `names(h INTEGER PRIMARY KEY)` = a 64-bit blake2b of `roles.fold(name)` - the same fold the
people check uses, applied in Python (no SQL copy of it to drift). 15.6M folded names, 229 MiB. A hash
collision could only make a person "found" (never "nowhere"); at 15.6M names in 2^64 that is ~1e-12 per
look-up. `meta` records when, how many rows were read, and how many Trino counted.

Freshness: younger than TTL_S is used as is. Between TTL_S and STALE_MAX_S one process rebuilds (non-blocking
lock) while the others keep using the old file. Missing or older than STALE_MAX_S: readers wait for the
builder (up to WAIT_S). A build that fails, or reads fewer rows than Trino counted, never replaces the
file; with no usable index the look-up raises, which people_check records as `graph_error` (never a pass).
"""
from __future__ import annotations

import csv
import fcntl
import hashlib
import os
import sqlite3
import time
from typing import Any, Callable

DEFAULT_PATH = "/var/lib/hydra-credit-verify/name-index.sqlite"
TTL_S = 6 * 3600
STALE_MAX_S = 24 * 3600
WAIT_S = 900
BUILD_LIMIT_S = 900
COMPLETE = 0.995            # a build must read at least this share of the rows Trino counted
SOURCE = "postgresql_catalog.public.catalog_profile"


class IndexUnavailable(RuntimeError):
    pass


def name_hash(folded: str) -> int:
    return int.from_bytes(hashlib.blake2b(folded.encode("utf-8"), digest_size=8).digest(), "big", signed=True)


def built_at(path: str) -> float | None:
    if not os.path.exists(path):
        return None
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            row = db.execute("SELECT v FROM meta WHERE k='built_at'").fetchone()
        finally:
            db.close()
        return float(row[0]) if row else None
    except (sqlite3.Error, ValueError):
        return None


def build(path: str, *, export: Callable[[str], None], count: Callable[[], int],
          now: Callable[[], float] = time.time) -> dict[str, Any]:
    """`export(file)` writes one CSV column of names to `file`; `count()` is Trino's row count.
    Builds next to `path` and replaces it atomically, only when complete."""
    from credit_review.roles import fold
    tmp, spool = f"{path}.tmp-{os.getpid()}", f"{path}.csv-{os.getpid()}"
    try:
        expected = int(count())
        fd = os.open(spool, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(fd)
        export(spool)
        db = sqlite3.connect(tmp)
        os.chmod(tmp, 0o600)
        db.execute("PRAGMA journal_mode=OFF")
        db.execute("PRAGMA synchronous=OFF")
        db.execute("CREATE TABLE names (h INTEGER PRIMARY KEY)")
        db.execute("CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)")
        rows, batch = 0, []
        with open(spool, newline="", encoding="utf-8", errors="replace") as fh:
            for r in csv.reader(fh):
                if len(r) != 1:
                    continue                    # a CLI line, never a name row
                rows += 1
                f = fold(r[0])
                if f:
                    batch.append((name_hash(f),))
                if len(batch) >= 200_000:
                    db.executemany("INSERT OR IGNORE INTO names VALUES (?)", batch)
                    batch = []
        db.executemany("INSERT OR IGNORE INTO names VALUES (?)", batch)
        if expected <= 0 or rows < expected * COMPLETE:
            raise IndexUnavailable(f"incomplete export: {rows} rows read, Trino counted {expected}")
        names = db.execute("SELECT count(*) FROM names").fetchone()[0]
        db.executemany("INSERT INTO meta VALUES (?, ?)", [("built_at", str(now())), ("rows", str(rows)),
                                                         ("expected", str(expected)), ("names", str(names))])
        db.commit()
        db.close()
        os.replace(tmp, path)
        return {"rows": rows, "expected": expected, "names": names}
    finally:
        for p in (tmp, spool):
            if os.path.exists(p):
                os.remove(p)


class LocalIndex:
    def __init__(self, path: str):
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)

    def __call__(self, folded: list[str]) -> set[str]:
        out = set()
        for f in {n for n in folded if n}:
            if self.db.execute("SELECT 1 FROM names WHERE h=?", (name_hash(f),)).fetchone():
                out.add(f)
        return out


def ensure(path: str, *, export: Callable[[str], None], count: Callable[[], int], now: Callable[[], float] = time.time,
           sleep: Callable[[float], None] = time.sleep, log: Callable[[str], None] = lambda m: None,
           wait_s: float = WAIT_S) -> LocalIndex:
    def age() -> float | None:
        b = built_at(path)
        return None if b is None else now() - b

    def stale_ok() -> LocalIndex:
        """The old file, only while it is still under STALE_MAX_S - re-measured at the moment it is served
        (QA #1467: a failed or slow rebuild must not serve an index past the 24 h maximum)."""
        b = age()
        if b is None or b >= STALE_MAX_S:
            raise IndexUnavailable(f"name index is {'missing' if b is None else f'{b / 3600:.1f} h old'} "
                                   f"(maximum {STALE_MAX_S / 3600:.0f} h) and the rebuild did not finish")
        return LocalIndex(path)

    a = age()
    if a is not None and a < TTL_S:
        return LocalIndex(path)
    fd = os.open(f"{path}.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if a is not None and a < STALE_MAX_S:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return stale_ok()                   # another process is rebuilding: the old file serves
            try:
                if (age() or 0) >= TTL_S:
                    log(f"name index: rebuilding ({a / 3600:.1f} h old) {build(path, export=export, count=count, now=now)}")
            except Exception as exc:  # noqa: BLE001 - a failed rebuild keeps the old file
                log(f"name index: rebuild failed, keeping the {a / 3600:.1f} h old one ({type(exc).__name__}: {exc})"[:300])
            return stale_ok()
        deadline = now() + wait_s
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if now() >= deadline:
                    raise IndexUnavailable("name index: another process is still building it")
                sleep(5)
        a = age()
        if a is None or a >= STALE_MAX_S:
            log(f"name index: building {build(path, export=export, count=count, now=now)}")
        return stale_ok()
    finally:
        os.close(fd)


def lazy(path: str = DEFAULT_PATH, *, export: Callable[[str], None] | None = None,
         count: Callable[[], int] | None = None, log: Callable[[str], None] = lambda m: None,
         **kw: Any) -> Callable[[list[str]], set[str]]:
    """The NameIndex the reader passes to people_check: the index is opened (or built) on the first
    look-up, so a run with no documents never touches Trino. An unavailable index raises on every
    look-up of the run (people_check records graph_error)."""
    state: dict[str, Any] = {}

    def look(folded: list[str]) -> set[str]:
        if "index" not in state:
            try:
                state["index"] = ensure(path, export=export or trino_export, count=count or trino_count, log=log, **kw)
            except Exception as exc:  # noqa: BLE001
                state["index"] = None
                state["why"] = f"{type(exc).__name__}: {exc}"[:200]
                log(f"name index unavailable: {state['why']}")
        if state["index"] is None:
            raise IndexUnavailable(state["why"])
        return state["index"](folded)
    return look


def trino_count() -> int:
    from credit_verify.proof import stage2
    out = stage2.trino_query(f"SELECT count(*) FROM {SOURCE} WHERE name IS NOT NULL")
    for r in csv.reader(out.splitlines()):
        if r and r[0].strip().isdigit():
            return int(r[0])
    raise IndexUnavailable("no row count from Trino")


def trino_export(dest: str) -> None:
    """One read-only scan, streamed to `dest` (the build's 0600 spool file)."""
    import subprocess
    from credit_verify.proof import stage2
    stmt = f"SET SESSION query_max_execution_time = '{BUILD_LIMIT_S}s'; SELECT name FROM {SOURCE} WHERE name IS NOT NULL"
    with open(dest, "w", encoding="utf-8") as fh:
        p = subprocess.run(["bash", stage2.TRINO], input=stmt, stdout=fh, stderr=subprocess.PIPE, text=True,
                           timeout=BUILD_LIMIT_S + 120, check=False)
    if p.returncode != 0:
        raise IndexUnavailable(f"trino rc={p.returncode}: {stage2.trino_error(p.stderr)}")
