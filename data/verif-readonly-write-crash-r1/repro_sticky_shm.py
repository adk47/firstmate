#!/usr/bin/env python3
"""Reproduce node-8's "attempt to write a readonly database" for a ROOT writer on a plain sqlite3.connect().

Run as real root in a throwaway container (it needs two uids), never on node-8:

    docker run --rm --tmpfs /t -v "$PWD/data/verif-readonly-write-crash-r1:/w:ro" python:3.12-slim \
        python3 /w/repro_sticky_shm.py

The layout is node-8's: a directory `root:1000 1770` (group-writable + sticky), a WAL-mode ledger `root:1000 0640`, a
reader running as 1000:1000 that opens it mode=ro, and fs.protected_regular=2 (the Ubuntu default; it is a host-wide
sysctl, so the container inherits the host's value).

With the repo's scripts/ mounted at /s it also runs the same sticky layout through the write opener the fix adds
(credit_review/ledger_open.open_rw), which must write on its FIRST use and report the reopen:

    docker run --rm --tmpfs /t -v "$PWD/data/verif-readonly-write-crash-r1:/w:ro" -v "$PWD/scripts:/s:ro" \
        python:3.12-slim python3 /w/repro_sticky_shm.py
"""
from __future__ import annotations

import os
import sqlite3
import stat
import sys
from pathlib import Path

READER = 1000


def show(d: Path, label: str) -> None:
    rows = []
    for p in sorted(d.iterdir()):
        st = p.stat()
        rows.append(f"{p.name}={st.st_uid}:{st.st_gid}:{stat.S_IMODE(st.st_mode):o}:{st.st_size}b")
    st = d.stat()
    print(f"    [{label}] dir={st.st_uid}:{st.st_gid}:{stat.S_IMODE(st.st_mode):o}  " + "  ".join(rows))


def as_reader(fn) -> None:
    """Run fn in a child that has dropped to 1000:1000 (the exporter pod's identity)."""
    pid = os.fork()
    if pid == 0:
        try:
            os.setgroups([])
            os.setgid(READER)
            os.setuid(READER)
            fn()
            os._exit(0)
        except BaseException as exc:      # noqa: BLE001 - a child reports and exits
            print(f"    reader failed: {type(exc).__name__}: {exc}")
            os._exit(1)
    os.waitpid(pid, 0)


def reader_open_close(db_path: Path) -> None:
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    n = db.execute("SELECT count(*) FROM t").fetchone()[0]
    db.close()
    print(f"    reader uid={os.getuid()} read {n} row(s) mode=ro and closed")


def root_write(db_path: Path, label: str) -> str:
    db = sqlite3.connect(str(db_path), timeout=5, isolation_level=None)
    try:
        db.execute("CREATE TABLE IF NOT EXISTS t (x)")       # what Ledger()/connect() do first: reads only
        seen = db.execute("SELECT count(*) FROM t").fetchone()[0]
        try:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT INTO t VALUES (1)")
            db.execute("COMMIT")
            out = f"WRITE OK (read {seen} first)"
        except sqlite3.OperationalError as exc:
            out = (f"WRITE FAILED after reading {seen} row(s): {exc} "
                   f"[{getattr(exc, 'sqlite_errorname', '?')} {getattr(exc, 'sqlite_errorcode', '?')}]")
    finally:
        db.close()
    print(f"    root uid={os.geteuid()} {label}: {out}")
    return out


def make(d: Path, dir_mode: int) -> Path:
    d.mkdir(parents=True)
    os.chown(d, 0, READER)
    os.chmod(d, dir_mode)
    p = d / "ledger.sqlite3"
    db = sqlite3.connect(str(p), isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE t (x)")
    db.close()                                # the last writer closes: SQLite deletes the -wal and the -shm
    os.chown(p, 0, READER)
    os.chmod(p, 0o640)
    return p


def scenario(root: Path, name: str, dir_mode: int) -> list[str]:
    print(f"\n== {name}: directory mode {dir_mode:o}")
    p = make(root / name, dir_mode)
    show(p.parent, "after the last root writer closed")
    as_reader(lambda: reader_open_close(p))
    show(p.parent, "after the uid-1000 reader")
    first = root_write(p, "1st writer after the reader")
    show(p.parent, "after that writer")
    second = root_write(p, "2nd writer")
    show(p.parent, "after the 2nd writer")
    return [first, second]


def fixed_write(lo, db_path: Path, label: str, **kwargs) -> str:
    del lo.EVENTS[:]
    db = lo.open_rw(str(db_path), opener="repro", timeout=5, **kwargs)
    try:
        db.execute("CREATE TABLE IF NOT EXISTS t (x)")
        seen = db.execute("SELECT count(*) FROM t").fetchone()[0]
        try:
            db.execute("INSERT INTO t VALUES (1)")
            db.commit()
            out = f"WRITE OK (read {seen} first, opens={db.ledger_opens})"
        except sqlite3.OperationalError as exc:
            out = f"WRITE FAILED: {type(exc).__name__}: {exc}"
    finally:
        db.close()
    print(f"    root uid={os.geteuid()} {label}: {out}")
    for line in lo.EVENTS:
        print(f"    event: {line}")
    return out + (" EVENT" if lo.EVENTS else "")


def fixed_scenario(lo, root: Path, name: str, **kwargs) -> str:
    print(f"\n== {name}: directory mode 1770, through ledger_open.open_rw")
    p = make(root / name, 0o1770)
    as_reader(lambda: reader_open_close(p))
    show(p.parent, "after the uid-1000 reader")
    out = fixed_write(lo, p, "1st writer after the reader", **kwargs)
    show(p.parent, "after that writer")
    return out


def unfixable_scenario(lo, root: Path) -> str:
    """A writer that is NOT root gets no re-own from SQLite, so a reopen cannot help: the error must say why."""
    name = "sticky, writer is uid 1001 in group 1000 (no reopen can help)"
    print(f"\n== {name}")
    p = make(root / name, 0o1770)
    os.chmod(p, 0o660)
    as_reader(lambda: reader_open_close(p))
    show(p.parent, "after the uid-1000 reader")
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.setgroups([READER]); os.setgid(READER); os.setuid(1001)
        db = lo.open_rw(str(p), opener="repro", timeout=5)
        try:
            db.execute("INSERT INTO t VALUES (1)")
            out = "WRITE OK"
        except sqlite3.OperationalError as exc:
            out = f"{type(exc).__name__} reason={getattr(exc, 'reason', '?')}: {exc}"
        os.write(w, out.encode())
        os._exit(0)
    os.waitpid(pid, 0)
    os.close(w)
    out = os.read(r, 65536).decode()
    print(f"    uid 1001: {out}")
    return out


def main() -> int:
    if os.geteuid() != 0:
        print("needs real root (two uids); run it in a throwaway container", file=sys.stderr)
        return 2
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/t")
    print(f"python {sys.version.split()[0]} sqlite {sqlite3.sqlite_version} "
          f"fs.protected_regular={Path('/proc/sys/fs/protected_regular').read_text().strip()}")
    sticky = scenario(root, "sticky-group-writable (node-8 today)", 0o1770)
    plain = scenario(root, "group-writable, no sticky bit (control)", 0o770)
    ok = ("readonly" in sticky[0] and sticky[1].startswith("WRITE OK")
          and plain[0].startswith("WRITE OK") and plain[1].startswith("WRITE OK"))
    print("\nRESULT:", "REPRODUCED - one root writer is read-only after the reader recreates the WAL files, "
          "only under the sticky bit" if ok else "NOT reproduced as described")
    if not Path("/s/credit_review/ledger_open.py").exists():
        return 0 if ok else 1
    sys.path.insert(0, "/s")
    from credit_review import ledger_open as lo     # noqa: PLC0415
    a = fixed_scenario(lo, root, "fix, autocommit (verify_ledger.connect)", isolation_level=None)
    b = fixed_scenario(lo, root, "fix, implicit transactions (Ledger)")
    c = unfixable_scenario(lo, root)
    fixed = (all(o.startswith("WRITE OK") and "opens=2" in o and o.endswith("EVENT") for o in (a, b))
             and "LedgerNotWritableError reason=permission_sticky_directory" in c)
    print("\nFIX:", "HOLDS - the write opener writes on its first use and reports the reopen; a writer no reopen can "
          "help is told the reason" if fixed else "DOES NOT HOLD")
    return 0 if ok and fixed else 1


if __name__ == "__main__":
    sys.exit(main())
