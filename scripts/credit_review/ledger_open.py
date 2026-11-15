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

Lock contention (2026-11-15: the intercom drain died mid-run on `database is locked` while four credit jobs wrote this
ledger at once). Waiting for another writer was each caller's own business - a `timeout=` it had to remember, a
journal mode nobody set (a ledger this module created was a rollback-journal file, where a writer shuts every reader
out and the reverse), and no second try. The timeout and the retry now live here, so no caller has to bring its own:

  4. `_connect()` gives EVERY connection, reader or writer, a busy timeout of at least BUSY_TIMEOUT_S, and states it
     in `PRAGMA busy_timeout`. A caller may ask for longer; none gets shorter.
  5. `open_rw()` NEVER changes the journal mode. It reads it with a zero busy timeout (so it never waits behind a
     writer), records it on the connection as `ledger_journal_mode`, and reports a ledger that is not in `wal`
     through EVENT_SINK. A non-WAL ledger still opens and still writes. The one-time conversion is
     `migrate_to_wal()`, run by hand (`python3 ledger_open.py migrate-to-wal <ledger>`), never by an opener.
     `open_ro()` never sets a journal mode either - a reader does not change the file.
  6. A statement or commit on a WRITE connection that SQLite answers with SQLITE_BUSY / SQLITE_LOCKED is tried
     LOCK_ATTEMPTS times in all (`retry_on_lock`), then raises `LedgerLockedError` - still a
     `sqlite3.OperationalError`, still carrying SQLite's words, and naming the attempts made. Nothing else is ever
     retried: not a constraint error, not `LedgerNotWritableError`, and not a statement SQLite may already have
     half-applied (`executemany` / `executescript`, see `_many_unsafe` / `_script_unsafe`).

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

# Lock contention. The busy timeout is SQLite's own wait inside one attempt; the attempts are this module's.
SQLITE_BUSY = 5
SQLITE_LOCKED = 6
SQLITE_BUSY_SNAPSHOT = 517          # SQLITE_BUSY | (2 << 8): this connection's read snapshot is stale
BUSY_TIMEOUT_S = 30.0               # the floor for every connection; never lower it
BUSY_TIMEOUT_MS = int(BUSY_TIMEOUT_S * 1000)
LOCK_ATTEMPTS = 3                   # tries in all, the first included
# The wait after the 1st, 2nd, 3rd failed try. With LOCK_ATTEMPTS = 3 the last try is followed by the raise, so only
# the first two are slept; the third is there for whoever raises LOCK_ATTEMPTS.
LOCK_BACKOFF_S = (0.2, 0.5, 1.0)

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


class LedgerLockedError(sqlite3.OperationalError):
    """SQLite answered busy / locked and this module is done trying. `attempts` is how many tries were made (1 where a
    second try could not be made safely, or could not succeed), `waited_s` the backoff slept between them."""

    def __init__(self, message: str, *, path: str, attempts: int, waited_s: float, lock: str):
        super().__init__(message)
        self.path = path
        self.attempts = attempts
        self.waited_s = waited_s
        self.lock = lock                # SQLite's own words: "database is locked", "database table is locked", ...


class LedgerJournalModeError(sqlite3.OperationalError):
    """The one-time WAL migration could not leave the ledger in WAL mode. `mode` is what SQLite answered."""

    def __init__(self, message: str, *, path: str, mode: str):
        super().__init__(message)
        self.path = path
        self.mode = mode


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
    if not isinstance(exc, sqlite3.Error):
        return False
    if isinstance(exc, (LedgerNotWritableError, LedgerLockedError, LedgerJournalModeError)):
        return False
    code = getattr(exc, "sqlite_errorcode", None)
    if isinstance(code, int):
        return code & 0xFF == SQLITE_READONLY
    return "readonly database" in str(exc)


_LOCK_WORDS = ("database is locked", "database table is locked", "database schema is locked")


def is_lock_error(exc: BaseException) -> bool:
    """SQLITE_BUSY or SQLITE_LOCKED in any of their extended forms - and nothing this module already named."""
    if not isinstance(exc, sqlite3.OperationalError):
        return False
    if isinstance(exc, (LedgerNotWritableError, LedgerLockedError, LedgerJournalModeError)):
        return False
    code = getattr(exc, "sqlite_errorcode", None)
    if isinstance(code, int):
        return code & 0xFF in (SQLITE_BUSY, SQLITE_LOCKED)
    return any(words in str(exc) for words in _LOCK_WORDS)


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


def _lock_words(exc: BaseException) -> str:
    text = str(exc)
    return next((words for words in _LOCK_WORDS if words in text), text or "database is locked")


def _busy_timeout_ms(db: sqlite3.Connection) -> int | None:
    try:
        return int(sqlite3.Connection.execute(db, "PRAGMA busy_timeout").fetchall()[0][0])
    except Exception:  # noqa: BLE001 - this only words an error message
        return None


def _locked(db: sqlite3.Connection, exc: BaseException, *, what: str, attempts: int, waited_s: float,
            gave_up: str = "") -> LedgerLockedError:
    path = getattr(db, "ledger_path", "") or "(no path)"
    opener = getattr(db, "ledger_opener", "")
    lock = _lock_words(exc)
    name = getattr(exc, "sqlite_errorname", None)
    if gave_up:
        tail = f"not tried again after attempt {attempts}: {gave_up}"
    else:
        ms = _busy_timeout_ms(db)
        inside = f", busy_timeout {ms} ms inside each" if ms is not None else ""
        tail = f"still locked after {attempts} attempts ({waited_s:g}s of backoff between them{inside})"
    return LedgerLockedError(
        f"ledger {path}{', opened by ' + opener if opener else ''}{' on ' + what if what else ''}: {lock} - {tail} "
        f"(sqlite: {exc}{' [' + name + ']' if name else ''})",
        path=path, attempts=attempts, waited_s=waited_s, lock=lock)


def retry_on_lock(db: sqlite3.Connection, call: Callable[[], Any], *, what: str = "",
                  unsafe: Callable[[], str] | None = None) -> Any:
    """Run `call`, and run it again when SQLite answers SQLITE_BUSY / SQLITE_LOCKED: LOCK_ATTEMPTS tries in all,
    LOCK_BACKOFF_S between them, then LedgerLockedError naming the lock and the tries made.

    Only a lock is retried. Any other error leaves on the first try, untouched - a constraint error (not an
    OperationalError at all), LedgerNotWritableError (a second try of a write the file refuses is the same refusal),
    and a lock this module already gave up on. Three locks are not retried either, and say why:

      * SQLITE_BUSY_SNAPSHOT: this connection read, another writer committed, and now it wants to write on the stale
        snapshot. No wait clears that - only the caller ending its transaction or its open SELECT does.
      * `unsafe()` answering a reason: the statement may already have taken effect in part (executemany,
        executescript), so a second run would apply that part twice.
      * write_state()'s probe, which asks with a zero busy timeout precisely so that it never waits."""
    waited = 0.0
    attempt = 0
    while True:
        attempt += 1
        try:
            result = call()
        except sqlite3.OperationalError as exc:
            if not is_lock_error(exc) or getattr(db, "ledger_lock_probe", False):
                raise
            gave_up = ""
            if getattr(exc, "sqlite_errorcode", None) == SQLITE_BUSY_SNAPSHOT:
                gave_up = ("this connection holds a read snapshot older than another writer's commit, which no wait "
                           "clears - end the transaction or the open SELECT and start again")
            elif unsafe is not None:
                gave_up = unsafe()
            if gave_up or attempt >= LOCK_ATTEMPTS:
                err = _locked(db, exc, what=what, attempts=attempt, waited_s=waited, gave_up=gave_up)
                _event(f"ledger-lock: {err}")
                raise err from exc
            pause = LOCK_BACKOFF_S[min(attempt, len(LOCK_BACKOFF_S)) - 1]
            time.sleep(pause)
            waited += pause
            continue
        if attempt > 1:
            _event(f"ledger-lock: {getattr(db, 'ledger_path', '') or '(no path)'}{' on ' + what if what else ''} was "
                   f"locked; attempt {attempt} of {LOCK_ATTEMPTS} went through after {waited:g}s of backoff")
        return result


def _what(args: tuple[Any, ...]) -> str:
    """The start of the statement, for the error: SQL text only - the parameters, which hold the data, are never
    part of it."""
    return " ".join(str(args[0]).split())[:60] if args else ""


def _many_unsafe(db: sqlite3.Connection, args: tuple[Any, ...], changes_before: int) -> str:
    """Why an executemany that met a lock may NOT be run again ('' when it may). In autocommit each row is its own
    transaction, so a lock met at row k leaves the rows before it written; and rows handed over as an iterator were
    consumed by the first try."""
    if len(args) < 2 or not isinstance(args[1], (list, tuple)):
        return "its rows came from an iterator the first try consumed"
    if db.total_changes != changes_before:
        return "the first try had already written rows, and a second would write them twice"
    return ""


def _script_state(db: sqlite3.Connection) -> tuple[int, Any]:
    try:
        version = sqlite3.Connection.execute(db, "PRAGMA schema_version").fetchall()[0][0]
    except sqlite3.Error:
        version = None
    return db.total_changes, version


def _script_unsafe(db: sqlite3.Connection, before: tuple[int, Any]) -> str:
    """Why an executescript that met a lock may NOT be run again ('' when it may): a script is many statements, each
    committed on its own unless the script says otherwise, so a lock met at statement k leaves the ones before it
    applied. It is run again only when nothing shows any of it took effect."""
    if db.in_transaction:
        return "the script left a transaction open"
    changes, version = _script_state(db)
    if changes != before[0]:
        return "the script had already changed rows"
    if version is None or before[1] is None or version != before[1]:
        return "the script had already changed the schema, or the schema could not be read to tell"
    return ""


def _run(db: Any, call: Callable[[], Any], *, what: str, unsafe: Callable[[], str] | None = None) -> Any:
    """What every statement and commit of a ledger connection goes through: a lock is retried on a WRITE connection
    (a reader's is left exactly as it was), and a refused write is explained."""
    try:
        if getattr(db, "ledger_read_only", False):
            return call()
        return retry_on_lock(db, call, what=what, unsafe=unsafe)
    except sqlite3.OperationalError as exc:
        better = explain(db, exc)
        if better is None:
            raise
        raise better from exc


def _run_many(db: Any, call: Callable[[], Any], args: tuple[Any, ...]) -> Any:
    before = db.total_changes
    return _run(db, call, what=_what(args), unsafe=lambda: _many_unsafe(db, args, before))


def _run_script(db: Any, call: Callable[[], Any]) -> Any:
    if getattr(db, "ledger_read_only", False):
        return _run(db, call, what="executescript")
    before = _script_state(db)
    return _run(db, call, what="executescript", unsafe=lambda: _script_unsafe(db, before))


class LedgerCursor(sqlite3.Cursor):
    def execute(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        return _run(self.connection, lambda: sqlite3.Cursor.execute(self, *args, **kwargs), what=_what(args))

    def executemany(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        return _run_many(self.connection, lambda: sqlite3.Cursor.executemany(self, *args, **kwargs), args)

    def executescript(self, *args: Any, **kwargs: Any) -> "LedgerCursor":
        return _run_script(self.connection, lambda: sqlite3.Cursor.executescript(self, *args, **kwargs))


class LedgerConnection(sqlite3.Connection):
    """A sqlite3.Connection that knows which ledger it is, whether it was opened to read or to write, and what the
    files beside it looked like at open - so a refused write can say why, and a write that meets another writer's
    lock is tried again (retry_on_lock). Nothing else about it differs."""

    ledger_path: str = ""
    ledger_opener: str = ""
    ledger_read_only: bool = False
    ledger_facts: Facts | None = None
    ledger_unwritable: tuple[str, str] | None = None     # set by open_rw when the open-time check found no way to write
    ledger_opens: int = 1
    ledger_journal_mode: str = ""                       # read at open, never set by an opener
    ledger_lock_probe: bool = False                      # True only inside write_state(): its busy answer is the answer

    def cursor(self, factory: Any = None) -> Any:        # every cursor explains, db.cursor().execute(...) included
        return super().cursor(factory or LedgerCursor)

    def execute(self, *args: Any, **kwargs: Any) -> Any:
        return _run(self, lambda: sqlite3.Connection.execute(self, *args, **kwargs), what=_what(args))

    def executemany(self, *args: Any, **kwargs: Any) -> Any:
        return _run_many(self, lambda: sqlite3.Connection.executemany(self, *args, **kwargs), args)

    def executescript(self, *args: Any, **kwargs: Any) -> Any:
        return _run_script(self, lambda: sqlite3.Connection.executescript(self, *args, **kwargs))

    def commit(self) -> None:
        return _run(self, lambda: sqlite3.Connection.commit(self), what="COMMIT")


class ReadOnlyLedgerConnection(LedgerConnection):
    ledger_read_only = True


def _connect(target: str, **kwargs: Any) -> sqlite3.Connection:
    """The one place this module calls sqlite3.connect (a test stands in a connection that got the read-only
    fallback here, which is the only way to produce one without two uids).

    Every connection - reader, writer, :memory: - leaves with a busy timeout of at least BUSY_TIMEOUT_S: a caller's
    longer `timeout=` is kept, a shorter or missing one is raised to the floor."""
    asked = kwargs.get("timeout")
    kwargs["timeout"] = max(float(asked), BUSY_TIMEOUT_S) if asked is not None else BUSY_TIMEOUT_S
    db = sqlite3.connect(target, **kwargs)
    try:
        # sqlite3.connect(timeout=) IS the busy timeout; it is said again as a PRAGMA so the value is one a test, or
        # anyone with the connection in hand, can read back. It touches no file.
        sqlite3.Connection.execute(db, f"PRAGMA busy_timeout={int(round(kwargs['timeout'] * 1000))}").close()
    except BaseException:
        db.close()
        raise
    return db


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
    probing = isinstance(db, LedgerConnection)
    if probing:
        db.ledger_lock_probe = True                 # the probe's busy answer is its answer: never retry_on_lock
    try:
        old = raw(db, "PRAGMA busy_timeout").fetchone()[0]
        raw(db, "PRAGMA busy_timeout=0")
        try:
            raw(db, "BEGIN IMMEDIATE")
            raw(db, "ROLLBACK")
        finally:
            # Back to what the connection had, and never below the floor: a zero left here is a writer that fails
            # the instant another one holds the lock.
            raw(db, f"PRAGMA busy_timeout={max(int(old), BUSY_TIMEOUT_MS)}")
    except sqlite3.Error as exc:
        return "read_only" if is_readonly_error(exc) else "inconclusive"
    finally:
        if probing:
            db.ledger_lock_probe = False
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


def read_journal_mode(db: sqlite3.Connection) -> str:
    """The ledger's journal mode, read with a zero busy timeout so it never waits behind another writer, and with the
    connection's timeout restored to at least the floor afterwards. 'unknown' when SQLite cannot answer."""
    raw = sqlite3.Connection.execute
    try:
        old = int(raw(db, "PRAGMA busy_timeout").fetchone()[0])
    except sqlite3.Error:
        old = BUSY_TIMEOUT_MS
    try:
        raw(db, "PRAGMA busy_timeout=0")
        try:
            return str(raw(db, "PRAGMA journal_mode").fetchall()[0][0])
        except sqlite3.Error:
            return "unknown"
    finally:
        try:
            raw(db, f"PRAGMA busy_timeout={max(old, BUSY_TIMEOUT_MS)}")
        except sqlite3.Error:
            pass


def migrate_to_wal(path: str) -> tuple[str, str]:
    """The one-time, operator-run conversion of a ledger to WAL: (mode before, mode after).

    Nothing calls this automatically - no opener, no timer, no deploy step. It converts only when no other connection
    holds a lock on the ledger: the busy timeout is zero, so a busy answer is raised at once rather than waited out,
    and there is no retry. It reads the mode back, and anything but `wal` raises `LedgerJournalModeError` naming the
    ACTUAL mode (a busy ledger, a read-only file or directory, `:memory:`). A path that does not exist is refused
    before connecting, so a mistyped path cannot create an empty ledger and report it as converted. A ledger already
    in WAL is left byte for byte as it was."""
    path = str(path)
    if path == ":memory:":
        raise LedgerJournalModeError(
            f"ledger {path} has no journal file: its journal mode is 'memory', not 'wal'", path=path, mode="memory")
    if not os.path.exists(path):
        raise LedgerJournalModeError(
            f"ledger {path} does not exist: refusing to create an empty one and report it as converted",
            path=path, mode="missing")
    db: LedgerConnection = _connect(path, factory=LedgerConnection)  # type: ignore[assignment]
    db.ledger_path = path
    raw = sqlite3.Connection.execute
    try:
        raw(db, "PRAGMA busy_timeout=0")
        before = read_journal_mode(db)
        if before.lower() == "wal":
            return before, before
        raw(db, "PRAGMA busy_timeout=0")
        try:
            raw(db, "PRAGMA journal_mode=WAL").fetchall()
        except sqlite3.Error as exc:
            after = read_journal_mode(db)
            raise LedgerJournalModeError(
                f"ledger {path} could not be put in WAL mode: it is in journal mode {after!r} and "
                f"PRAGMA journal_mode=WAL failed (sqlite: {exc})", path=path, mode=after) from exc
        after = read_journal_mode(db)
        if after.lower() != "wal":
            raise LedgerJournalModeError(
                f"ledger {path} is in journal mode {after!r}, not 'wal': PRAGMA journal_mode=WAL answered {after!r}. "
                f"A ledger is not left on a rollback journal - that is the mode in which writers and readers lock "
                f"each other out.", path=path, mode=after)
        return before, after
    finally:
        db.close()


def open_rw(path: str, *, opener: str = "", **connect_kwargs: Any) -> LedgerConnection:
    """The WRITE opener. Returns a connection that can write, reopening when the first one got SQLite's silent
    read-only fallback and a reopen can cure it.

    It never raises for an unwritable ledger: plenty of callers open the decider ledger and only read. The connection
    carries the diagnosis instead, and its first refused write raises LedgerNotWritableError with it.

    It never changes the journal mode. It reads it into `ledger_journal_mode` and reports a ledger that is not in
    `wal` through EVENT_SINK; the conversion is `migrate_to_wal()`, run by hand. (`:memory:` has no journal file and
    is passed through.)"""
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
        db.ledger_journal_mode = read_journal_mode(db)
        if db.ledger_journal_mode.lower() != "wal":
            _event(f"ledger-open: {path}{', opened by ' + opener if opener else ''} is in journal mode "
                   f"{db.ledger_journal_mode!r}, not 'wal'; the one-time conversion is "
                   f"`python3 ledger_open.py migrate-to-wal {path}`")
        writable = write_state(db) != "read_only" and not _db_file_unwritable(facts)
        if writable:
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


def main(argv: list[str] | None = None) -> int:
    """`python3 ledger_open.py migrate-to-wal <ledger>`: the one-time conversion, run by hand."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] != "migrate-to-wal":
        sys.stderr.write("usage: ledger_open.py migrate-to-wal <ledger.sqlite3>\n")
        return 2
    path = args[1]
    try:
        before, after = migrate_to_wal(path)
    except LedgerJournalModeError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1
    if before.lower() == "wal":
        sys.stdout.write(f"{path}: already in WAL mode; nothing written\n")
    else:
        sys.stdout.write(f"{path}: journal mode {before} -> {after}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


# One copy per process, whichever way this file was reached first (see the module docstring). Keep this the LAST
# statement: a module may replace itself in sys.modules, and the import system hands back what it finds there.
SHARED_NAME = "credit_review_ledger_open"
if sys.modules.setdefault(SHARED_NAME, sys.modules[__name__]) is not sys.modules[__name__]:
    sys.modules[__name__] = sys.modules[SHARED_NAME]
