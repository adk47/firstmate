"""One opener for a ledger a process WRITES, one for a ledger it only READS, and an error that says which it was.

Why this exists (2026-11-13, six crashed runs in two days, `sqlite3.OperationalError: attempt to write a readonly
database`): every one of them was a ROOT process on a plain `sqlite3.connect()` - verify_ledger.connect()'s write
branch (uvn-status, claim-proof-ask) and the decider's Ledger() - never a `mode=ro` opener. The connection was
read-only because of who owned two files beside the ledger:

  * the last root writer closes, and SQLite deletes `ledger.sqlite3-wal` and `-shm`;
  * the next opener is the read-only exporter pod (uid 1000), which re-creates both, owned by uid 1000;
  * the directory is `root:1000 1770` - group-writable AND sticky - and node-8 runs `fs.protected_regular=2`, so the
    kernel refuses the `O_CREAT` open SQLite makes on those files to everyone but their owner, root included
    (openat(2): EACCES, "sticky_create_regular");
  * SQLite does not report that. It falls back to a read-only handle on the WAL, every read works, and the first
    WRITE - minutes later in the decider's case - fails with the bare message above;
  * as root it also re-owns the two files to the ledger's owner on that same open, so the NEXT writer succeeds and
    the cause is gone from the disk by the time anyone looks.

Reproduced end to end, with the no-sticky-bit control, by data/verif-readonly-write-crash-r1/repro_sticky_shm.py.

So this module does three things and changes no file mode or owner itself:

  1. `open_rw()` asks, at open, whether this connection can write (a write lock taken and rolled back with a zero busy
     timeout, so it never waits behind a real writer and never writes a byte). A writer that got the read-only
     fallback is reopened where a reopen can differ - SQLite's own re-own on the failed open is what makes root's
     second open writable - at most RW_OPEN_ATTEMPTS opens, and every such reopen is reported through EVENT_SINK,
     never silent.
  2. A write that still cannot happen raises `LedgerNotWritableError` naming the reason - read-only mode, permission
     (which file, whose it is, the sticky rule), a read-only filesystem, a moved file - with the facts read at open.
     It IS a `sqlite3.OperationalError`, so every existing handler still catches it.
  3. `open_ro()` returns a connection that knows it is a reader: a write on it raises `ReadOnlyConnectionWriteError`
     (reason `read_only_mode`) and is never reopened, never retried.

Standard library only, and no sibling import: verify_ledger.py is also run as a file (`python3 -I verify_ledger.py`),
where there is no package, so it loads this file by path (verify_ledger.ledger_open()). However it is reached - that
loader, or `from credit_review import ledger_open` - a process holds ONE copy of it (the last statement of this file):
two copies would mean two EVENT_SINKs and an `except LedgerNotWritableError` that does not match the error raised.
"""

from __future__ import annotations

import os
import sqlite3
import stat
import sys
import time
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

SQLITE_READONLY = 8

# A reopen only helps where SQLite re-owned the WAL files on the failed open, which it does as root only. Three opens
# 0.2 s apart: the second is the one that works (measured in the repro); the third is margin for a reader that
# re-creates the files again in between.
RW_OPEN_ATTEMPTS = 3
RW_REOPEN_SLEEP_S = 0.2

# Where a reopen (or a ledger that stays read-only for a writer) is reported. credit-review.py points this at the run
# log; a caller that sets nothing still gets EVENTS. Never stderr: the crons are command crons that post stderr.
EVENT_SINK: Callable[[str], Any] | None = None
EVENTS: list[str] = []
_EVENTS_KEPT = 50

# Reason codes (LedgerNotWritableError.reason). A caller branches on these, never on the sentence.
READ_ONLY_MODE = "read_only_mode"              # the connection was opened as a reader (mode=ro)
PERMISSION = "permission"                      # this uid may not write the ledger, its -wal or its -shm
STICKY_DIRECTORY = "permission_sticky_directory"   # fs.protected_regular: a WAL file another uid created
READ_ONLY_FILESYSTEM = "read_only_filesystem"
PATH_MOVED = "path"                            # the file at this path is not the one that was opened
UNKNOWN = "unknown"

# The extended SQLITE_READONLY_* codes: every one of them carries the same message as a plain write refusal, and most
# of them are raised on a READ. Mapped so a reader that could not initialise the -shm is never told "you wrote".
_EXTENDED = {
    264: (PERMISSION, "the WAL needs recovery and this connection may not write it (SQLITE_READONLY_RECOVERY)"),
    520: (PERMISSION, "the -shm cannot be locked because it is not writable (SQLITE_READONLY_CANTLOCK)"),
    776: (PERMISSION, "a rollback journal needs replaying and this connection may not write (SQLITE_READONLY_ROLLBACK)"),
    1032: (PATH_MOVED, "the database file was moved or replaced after it was opened (SQLITE_READONLY_DBMOVED)"),
    1288: (PERMISSION, "the -shm needs initialising and is not writable (SQLITE_READONLY_CANTINIT)"),
    1544: (PERMISSION, "the directory is not writable, so the -shm cannot be created (SQLITE_READONLY_DIRECTORY)"),
}


class LedgerNotWritableError(sqlite3.OperationalError):
    """A write the ledger refused, with the reason. `reason` is one of the codes above, `why` the sentence, `path`
    the ledger, `facts` the owners and modes read when the connection was opened."""

    def __init__(self, message: str, *, reason: str, why: str, path: str, facts: "Facts | None" = None):
        super().__init__(message)
        self.reason = reason
        self.why = why
        self.path = path
        self.facts = facts


class ReadOnlyConnectionWriteError(LedgerNotWritableError):
    """A write on a connection that was opened read-only. Not a fault of the file: the caller holds a reader."""


@dataclass(frozen=True)
class FileFacts:
    uid: int
    gid: int
    mode: int                 # permission bits, sticky / setgid included (stat.S_IMODE)

    def render(self) -> str:
        return f"{self.uid}:{self.gid}:{self.mode:o}"


@dataclass(frozen=True)
class Facts:
    """Who is opening, and who owns what, read BEFORE the open: as root SQLite re-owns the -wal and -shm on the very
    open that fails, so the evidence is not on the disk afterwards."""
    path: str
    euid: int
    groups: frozenset[int]
    directory: FileFacts | None
    db: FileFacts | None
    wal: FileFacts | None
    shm: FileFacts | None
    protected_regular: int | None      # /proc/sys/fs/protected_regular; None where it cannot be read
    fs_read_only: bool | None
    taken_at: str

    def render(self) -> str:
        def one(label: str, f: FileFacts | None) -> str:
            return f"{label}={f.render() if f else 'absent'}"
        pr = "unreadable" if self.protected_regular is None else str(self.protected_regular)
        return (f"uid={self.euid} " + " ".join(one(k, v) for k, v in (
            ("dir", self.directory), ("db", self.db), ("wal", self.wal), ("shm", self.shm)))
            + f" fs.protected_regular={pr} (owner:group:mode, read at {self.taken_at})")


def _file_facts(path: str) -> FileFacts | None:
    try:
        st = os.stat(path)
    except OSError:
        return None
    return FileFacts(st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode))


def _protected_regular() -> int | None:
    try:
        return int(Path("/proc/sys/fs/protected_regular").read_text().strip())
    except (OSError, ValueError):
        return None


def snapshot(path: str) -> Facts:
    """Stat only. Never opens, creates or changes anything."""
    path = str(path)
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fs_ro: bool | None
    try:
        fs_ro = bool(os.statvfs(directory).f_flag & os.ST_RDONLY)
    except (OSError, AttributeError):
        fs_ro = None
    try:
        groups = frozenset({os.getegid(), *os.getgroups()})
    except OSError:
        groups = frozenset({os.getegid()})
    return Facts(path=path, euid=os.geteuid(), groups=groups, directory=_file_facts(directory), db=_file_facts(path),
                 wal=_file_facts(path + "-wal"), shm=_file_facts(path + "-shm"),
                 protected_regular=_protected_regular(), fs_read_only=fs_ro,
                 taken_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))


def _may_write(f: FileFacts, euid: int, groups: frozenset[int]) -> bool:
    if euid == 0:
        return True
    if f.uid == euid:
        return bool(f.mode & 0o200)
    if f.gid in groups:
        return bool(f.mode & 0o020)
    return bool(f.mode & 0o002)


def sticky_refuses(directory: FileFacts | None, f: FileFacts | None, euid: int, protected_regular: int | None) -> bool:
    """The kernel's may_create_in_sticky() (fs/namei.c) for a regular file: an O_CREAT open of an EXISTING file is
    refused with EACCES when the directory is sticky, the file belongs neither to the opener nor to the directory's
    owner, and the directory is world-writable (fs.protected_regular >= 1) or group-writable (>= 2). Capabilities do
    not lift it: root is refused too."""
    if not directory or not f or not protected_regular:
        return False
    if not directory.mode & stat.S_ISVTX or f.uid == directory.uid or f.uid == euid:
        return False
    return bool(directory.mode & 0o002) or bool(directory.mode & 0o020 and protected_regular >= 2)


def classify(facts: Facts | None, *, read_only_mode: bool = False) -> tuple[str, str]:
    """(reason code, sentence) for a write SQLite refused. Pure: it reads nothing, so node-8's layout is a fixture."""
    if read_only_mode:
        return READ_ONLY_MODE, ("this connection was opened read-only (mode=ro): it is a reader, and a reader never "
                                "writes. The caller needs the write opener")
    if facts is None:
        return UNKNOWN, "SQLite reports the database read-only and the files beside it were not read at open"
    name = os.path.basename(facts.path)
    if facts.fs_read_only:
        return READ_ONLY_FILESYSTEM, f"the filesystem holding {facts.path} is mounted read-only"
    if facts.db and not _may_write(facts.db, facts.euid, facts.groups):
        return PERMISSION, (f"uid {facts.euid} may not write {name} (owner {facts.db.uid}, group {facts.db.gid}, "
                            f"mode {facts.db.mode:o})")
    for suffix, f in (("-wal", facts.wal), ("-shm", facts.shm)):
        if sticky_refuses(facts.directory, f, facts.euid, facts.protected_regular):
            assert f is not None and facts.directory is not None
            return STICKY_DIRECTORY, (
                f"{name}{suffix} was created by uid {f.uid}, and its directory is sticky (mode "
                f"{facts.directory.mode:o}, owner {facts.directory.uid}): with fs.protected_regular="
                f"{facts.protected_regular} the kernel refuses the open SQLite makes on it to every uid but its "
                f"owner, uid {facts.euid} included, so SQLite fell back to a read-only handle. A reader re-created "
                "the WAL files after the last writer closed")
    for suffix, f in (("-wal", facts.wal), ("-shm", facts.shm)):
        if f and not _may_write(f, facts.euid, facts.groups):
            return PERMISSION, (f"uid {facts.euid} may not write {name}{suffix} (owner {f.uid}, group {f.gid}, "
                                f"mode {f.mode:o})")
    if facts.db is None and facts.directory and not _may_write(facts.directory, facts.euid, facts.groups):
        return PERMISSION, (f"uid {facts.euid} may not create {name} in its directory (owner {facts.directory.uid}, "
                            f"group {facts.directory.gid}, mode {facts.directory.mode:o})")
    return UNKNOWN, "SQLite reports the database read-only and no known cause matches the files beside it"


def is_readonly_error(exc: BaseException) -> bool:
    """SQLITE_READONLY in any of its extended forms."""
    if not isinstance(exc, sqlite3.Error) or isinstance(exc, LedgerNotWritableError):
        return False
    code = getattr(exc, "sqlite_errorcode", None)
    if isinstance(code, int):
        return code & 0xFF == SQLITE_READONLY
    return "readonly database" in str(exc)


def _event(line: str) -> None:
    EVENTS.append(line)
    del EVENTS[:-_EVENTS_KEPT]
    sink = EVENT_SINK
    if sink is not None:
        try:
            sink(line)
        except Exception:  # noqa: BLE001 - a log line never fails the open it describes
            pass


def explain(db: "LedgerConnection", exc: BaseException) -> LedgerNotWritableError | None:
    """The legible error for a read-only refusal on this connection; None for anything else (the caller re-raises)."""
    if not is_readonly_error(exc):
        return None
    path = db.ledger_path or "(unnamed ledger)"
    code = getattr(exc, "sqlite_errorcode", None)
    cls: type[LedgerNotWritableError] = LedgerNotWritableError
    facts = db.ledger_facts
    if isinstance(code, int) and code in _EXTENDED:
        reason, why = _EXTENDED[code]
    elif db.ledger_read_only:
        cls = ReadOnlyConnectionWriteError
        reason, why = classify(facts, read_only_mode=True)
    else:
        reason, why = db.ledger_unwritable or classify(facts)
        if reason == UNKNOWN and db.ledger_path:
            now = snapshot(db.ledger_path)                 # the cause may have appeared after the open
            again = classify(now)
            if again[0] != UNKNOWN:
                (reason, why), facts = again, now
    detail = f" [{facts.render()}]" if facts is not None and reason != READ_ONLY_MODE else ""
    opener = f", opened by {db.ledger_opener}" if db.ledger_opener else ""
    return cls(f"cannot write ledger {path}{opener}: {reason} - {why}{detail} (sqlite: {exc})",
               reason=reason, why=why, path=path, facts=facts)


class LedgerCursor(sqlite3.Cursor):
    def execute(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        try:
            return super().execute(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self.connection, exc)       # type: ignore[arg-type]
            if better is None:
                raise
            raise better from exc

    def executemany(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        try:
            return super().executemany(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self.connection, exc)       # type: ignore[arg-type]
            if better is None:
                raise
            raise better from exc

    def executescript(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        try:
            return super().executescript(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self.connection, exc)       # type: ignore[arg-type]
            if better is None:
                raise
            raise better from exc


class LedgerConnection(sqlite3.Connection):
    """A sqlite3.Connection that knows which ledger it is, whether it was opened to read or to write, and what the
    files beside it looked like at open - so a refused write can say why. Nothing else about it differs."""

    ledger_path: str = ""
    ledger_opener: str = ""
    ledger_read_only: bool = False
    ledger_facts: Facts | None = None
    ledger_unwritable: tuple[str, str] | None = None     # set by open_rw when the open-time check found no way to write
    ledger_opens: int = 1

    def cursor(self, factory: Any = None) -> Any:        # every cursor explains, db.cursor().execute(...) included
        return super().cursor(factory or LedgerCursor)

    def execute(self, *args: Any, **kwargs: Any) -> Any:
        try:
            return super().execute(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self, exc)
            if better is None:
                raise
            raise better from exc

    def executemany(self, *args: Any, **kwargs: Any) -> Any:
        try:
            return super().executemany(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self, exc)
            if better is None:
                raise
            raise better from exc

    def executescript(self, *args: Any, **kwargs: Any) -> Any:
        try:
            return super().executescript(*args, **kwargs)
        except sqlite3.OperationalError as exc:
            better = explain(self, exc)
            if better is None:
                raise
            raise better from exc

    def commit(self) -> None:
        try:
            super().commit()
        except sqlite3.OperationalError as exc:
            better = explain(self, exc)
            if better is None:
                raise
            raise better from exc


class ReadOnlyLedgerConnection(LedgerConnection):
    ledger_read_only = True


def _connect(target: str, **kwargs: Any) -> sqlite3.Connection:
    """The one place this module calls sqlite3.connect (a test stands in a connection that got the read-only
    fallback here, which is the only way to produce one without two uids)."""
    return sqlite3.connect(target, **kwargs)


def write_state(db: sqlite3.Connection) -> str:
    """'writable', 'read_only' or 'inconclusive' - whether this connection's WAL handle can write, asked of SQLite
    without waiting and without writing.

    BEGIN IMMEDIATE on a connection whose WAL handle is read-only answers SQLITE_READONLY before it looks at the write
    lock (sqlite3WalBeginWriteTransaction), so with a zero busy timeout a busy answer means another writer holds a
    lock this connection could otherwise have taken. Busy is therefore 'inconclusive', never 'read_only', and never a
    failed open.

    It does NOT see a read-only database FILE (mode 0444, mode=ro): there SQLite quietly turns BEGIN IMMEDIATE into a
    read transaction and answers OK (measured, 3.45.1). open_rw() reads the file's mode for that case."""
    raw = sqlite3.Connection.execute
    try:
        old = raw(db, "PRAGMA busy_timeout").fetchone()[0]
        raw(db, "PRAGMA busy_timeout=0")
        try:
            raw(db, "BEGIN IMMEDIATE")
            raw(db, "ROLLBACK")
        finally:
            raw(db, f"PRAGMA busy_timeout={int(old)}")
    except sqlite3.Error as exc:
        return "read_only" if is_readonly_error(exc) else "inconclusive"
    return "writable"


def _db_file_unwritable(facts: Facts) -> bool:
    """The case write_state() cannot see: the database file itself may not be written by this uid."""
    return bool(facts.fs_read_only) or bool(facts.db and not _may_write(facts.db, facts.euid, facts.groups))


def _reopen_can_help(facts: Facts) -> bool:
    """A second open differs from the first only where SQLite's failed open changed the WAL files, which it does in
    two cases (os_unix.c): as ROOT it fchowns the -wal and -shm it just opened to the database's owner (node-8), and
    as a file's OWNER it fchmods an empty one to the database's mode. For any other uid, and where the database file
    itself may not be written, a reopen sees exactly what the first open did - so none is made."""
    if _db_file_unwritable(facts):
        return False
    return facts.euid == 0 or any(f is not None and f.uid == facts.euid for f in (facts.wal, facts.shm))


def open_rw(path: str, *, opener: str = "", **connect_kwargs: Any) -> LedgerConnection:
    """The WRITE opener. Returns a connection that can write, reopening when the first one got SQLite's silent
    read-only fallback and a reopen can cure it.

    It never raises for an unwritable ledger: plenty of callers open the decider ledger and only read. The connection
    carries the diagnosis instead, and its first refused write raises LedgerNotWritableError with it."""
    path = str(path)
    if path == ":memory:":
        return _connect(path, factory=LedgerConnection, **connect_kwargs)       # type: ignore[return-value]
    first: tuple[tuple[str, str], Facts] | None = None
    attempt = 0
    while True:
        attempt += 1
        facts = snapshot(path)
        db: LedgerConnection = _connect(path, factory=LedgerConnection, **connect_kwargs)  # type: ignore[assignment]
        db.ledger_path, db.ledger_opener, db.ledger_facts, db.ledger_opens = path, opener, facts, attempt
        if write_state(db) != "read_only" and not _db_file_unwritable(facts):
            if first is not None:
                _event(f"ledger-open: {path} gave this writer a read-only connection ({first[0][0]}: {first[0][1]} "
                       f"[{first[1].render()}]); reopened writable on open {attempt} of {RW_OPEN_ATTEMPTS}")
            return db
        found = classify(facts)
        if first is None or (first[0][0] == UNKNOWN and found[0] != UNKNOWN):
            first = (found, facts)
        if attempt >= RW_OPEN_ATTEMPTS or not _reopen_can_help(facts):
            db.ledger_unwritable, db.ledger_facts = first
            _event(f"ledger-open: {path} is read-only for this writer after {attempt} open(s) and stays so "
                   f"({first[0][0]}: {first[0][1]} [{first[1].render()}]); the first write will fail")
            return db
        db.close()
        time.sleep(RW_REOPEN_SLEEP_S)


def open_ro(path: str, *, opener: str = "", **connect_kwargs: Any) -> ReadOnlyLedgerConnection:
    """The READ opener: mode=ro, never created, never reopened. The path is percent-encoded into the URI - a raw '?'
    or '#' would end it early and open a different, writable file without mode=ro (QA #1564)."""
    resolved = str(Path(path).resolve())
    db: ReadOnlyLedgerConnection = _connect(                                      # type: ignore[assignment]
        f"file:{urllib.parse.quote(resolved)}?mode=ro", uri=True, factory=ReadOnlyLedgerConnection, **connect_kwargs)
    db.ledger_path, db.ledger_opener = str(path), opener
    return db


# One copy per process, whichever way this file was reached first (see the module docstring). Keep this the LAST
# statement: a module may replace itself in sys.modules, and the import system hands back what it finds there.
SHARED_NAME = "credit_review_ledger_open"
if sys.modules.setdefault(SHARED_NAME, sys.modules[__name__]) is not sys.modules[__name__]:
    sys.modules[__name__] = sys.modules[SHARED_NAME]
