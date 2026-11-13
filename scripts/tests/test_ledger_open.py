#!/usr/bin/env python3
"""The ledger's read opener and write opener (credit_review/ledger_open.py).

Pinned incident, 2026-11-12 10:35Z to 2026-11-13 03:12Z: six runs ended on a bare
`sqlite3.OperationalError: attempt to write a readonly database` - uvn-status and claim-proof-ask on the BEGIN
IMMEDIATE in verify_ledger._migrate, the decider on its first INSERT. Every one was root on a plain connect, not a
mode=ro opener: the read-only exporter pod (uid 1000) had re-created ledger.sqlite3-wal and -shm in a `root:1000 1770`
directory, and with fs.protected_regular=2 the kernel refuses root's open of them, so SQLite handed the writer a
read-only connection without saying so.

What must hold:
  * a write on a connection opened READ-ONLY raises, and the error says the caller holds a reader;
  * a write a WRITE connection is refused names the reason (which file, whose, why), never a bare database error;
  * a writer handed the read-only fallback is reopened where a reopen can cure it, and the reopen is reported;
  * the read-only flag a kill-switch dry run sets does not outlive that run.

The two-uid layout itself cannot run here (CI is one non-root user); it is reproduced, with its no-sticky-bit control
and with the fix, by data/verif-readonly-write-crash-r1/repro_sticky_shm.py in a container. Here a real read-only WAL
handle is produced by taking the write bit off the -wal, and node-8's ownership is a fixture for the pure classifier.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import contextlib
import hashlib
import importlib.util
import io
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import ledger_open  # noqa: E402
from credit_review import runner  # noqa: E402
from credit_review import verify_ledger  # noqa: E402
from credit_review.ledger import Ledger  # noqa: E402

NOT_ROOT = "the write bit means nothing to root; the two-uid case runs in the container repro"


def sha(path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.path = str(self.dir / "ledger.sqlite3")
        del ledger_open.EVENTS[:]
        self.addCleanup(lambda: ledger_open.EVENTS.__delitem__(slice(None)))
        self._held: list[sqlite3.Connection] = []
        self.addCleanup(lambda: [c.close() for c in self._held])

    def make(self, *, wal: bool = True) -> str:
        db = sqlite3.connect(self.path, isolation_level=None)
        if wal:
            db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE t (x)")
        db.execute("INSERT INTO t VALUES (1)")
        db.close()
        return self.path

    def hold_wal(self) -> None:
        """A reader that stays open, so the -wal and -shm stay on disk (the exporter's part on node-8)."""
        c = sqlite3.connect(self.path)
        c.execute("SELECT count(*) FROM t").fetchall()
        self._held.append(c)
        self.assertTrue(os.path.exists(self.path + "-wal"))

    def wal_without_the_write_bit(self, *, empty: bool = False) -> None:
        """A REAL read-only WAL handle for whoever opens next: reads work, a write is refused.

        empty=True is node-8's shape in miniature: SQLite repairs an EMPTY -wal it may not write on the open that
        fails (fchmod as its owner here, fchown as root there), so exactly one opener is read-only and the next can
        write. With frames in the -wal it leaves the file alone, and every open stays read-only."""
        if empty:
            self.make()                                   # the writer closed: checkpointed, -wal and -shm deleted
            self.hold_wal()                               # a reader re-creates them, empty
            self.assertEqual(os.path.getsize(self.path + "-wal"), 0)
        else:
            writer = sqlite3.connect(self.path, isolation_level=None)
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE t (x)")
            self.hold_wal()
            writer.execute("INSERT INTO t VALUES (1)")
            writer.close()                                # a reader is still attached: the frames stay in the -wal
            self.assertGreater(os.path.getsize(self.path + "-wal"), 0)
        os.chmod(self.path + "-wal", 0o444)
        self.addCleanup(lambda: os.path.exists(self.path + "-wal") and os.chmod(self.path + "-wal", 0o644))


class ReadOnlyConnectionTests(Base):
    """Acceptance 2: a write attempted on a read-only connection fails, by name."""

    WRITES = (
        ("execute", lambda db: db.execute("INSERT INTO t VALUES (2)")),
        ("cursor().execute", lambda db: db.cursor().execute("INSERT INTO t VALUES (2)")),
        ("executemany", lambda db: db.executemany("INSERT INTO t VALUES (?)", [(2,), (3,)])),
        ("executescript", lambda db: db.executescript("INSERT INTO t VALUES (2);")),
        ("ddl", lambda db: db.execute("CREATE TABLE u (y)")),
        ("delete", lambda db: db.execute("DELETE FROM t")),
    )

    def test_every_way_to_write_on_the_read_opener_raises_and_changes_nothing(self):
        self.make()
        before = sha(self.path)
        db = ledger_open.open_ro(self.path, opener="a test")
        self.addCleanup(db.close)
        for name, write in self.WRITES:
            with self.subTest(name), self.assertRaises(ledger_open.ReadOnlyConnectionWriteError) as caught:
                write(db)
            exc = caught.exception
            self.assertEqual(exc.reason, ledger_open.READ_ONLY_MODE)
            self.assertIn(self.path, str(exc))
            self.assertIn("opened by a test", str(exc))
            self.assertIn("opened read-only", str(exc))
        self.assertEqual(db.execute("SELECT count(*) FROM t").fetchone()[0], 1)      # it still reads
        self.assertEqual(sha(self.path), before)
        self.assertEqual(ledger_open.EVENTS, [])                                    # a reader is never "reopened"

    def test_the_error_is_still_the_database_error_every_handler_catches(self):
        self.make()
        db = ledger_open.open_ro(self.path)
        self.addCleanup(db.close)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO t VALUES (2)")
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("INSERT INTO t VALUES (2)")
        self.assertTrue(issubclass(ledger_open.ReadOnlyConnectionWriteError, ledger_open.LedgerNotWritableError))

    def test_any_other_error_on_a_reader_is_left_alone(self):
        self.make()
        db = ledger_open.open_ro(self.path)
        self.addCleanup(db.close)
        with self.assertRaises(sqlite3.OperationalError) as caught:
            db.execute("SELECT * FROM no_such_table")
        self.assertNotIsInstance(caught.exception, ledger_open.LedgerNotWritableError)

    def test_a_write_on_verify_ledgers_read_only_connection_raises(self):
        verify_ledger.connect(self.path).close()
        before = sha(self.path)
        db = verify_ledger.connect_ro(self.path)
        self.addCleanup(db.close)
        table = verify_ledger.TABLES[0]
        with self.assertRaises(ledger_open.ReadOnlyConnectionWriteError) as caught:
            db.execute(f'DELETE FROM "{table}"')
        self.assertEqual(caught.exception.reason, ledger_open.READ_ONLY_MODE)
        self.assertIn("verify_ledger.connect_ro", str(caught.exception))
        self.assertEqual(sha(self.path), before)

    def test_a_question_mark_in_the_path_opens_that_file_read_only(self):
        odd = str(self.dir / "ledger.db?mode=rwc")
        db = sqlite3.connect(odd)
        db.execute("CREATE TABLE t (x)")
        db.commit()
        db.close()
        ro = ledger_open.open_ro(odd)
        self.addCleanup(ro.close)
        with self.assertRaises(ledger_open.ReadOnlyConnectionWriteError):
            ro.execute("INSERT INTO t VALUES (1)")
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["ledger.db?mode=rwc"])

    def test_the_read_opener_never_creates_a_ledger(self):
        with self.assertRaises(sqlite3.OperationalError):
            ledger_open.open_ro(self.path).execute("SELECT 1")
        self.assertFalse(os.path.exists(self.path))


class WriteOpenerTests(Base):
    def test_a_healthy_ledger_opens_once_writes_and_reports_nothing(self):
        self.make()
        db = ledger_open.open_rw(self.path, opener="a test", timeout=30)
        self.addCleanup(db.close)
        self.assertIsInstance(db, ledger_open.LedgerConnection)
        self.assertFalse(db.ledger_read_only)
        self.assertEqual(db.ledger_opens, 1)
        db.execute("INSERT INTO t VALUES (2)")
        db.commit()
        self.assertEqual(db.execute("SELECT count(*) FROM t").fetchone()[0], 2)
        self.assertEqual(ledger_open.EVENTS, [])

    def test_the_open_time_check_writes_nothing(self):
        for wal in (True, False):
            with self.subTest(wal=wal):
                self.make(wal=wal)
                before = sha(self.path)
                ledger_open.open_rw(self.path, timeout=30).close()
                self.assertEqual(sha(self.path), before)
                self.assertFalse(os.path.exists(self.path + "-wal") and os.path.getsize(self.path + "-wal"))
                os.unlink(self.path)

    def test_another_writer_holding_the_lock_is_not_read_as_read_only_and_is_not_waited_for(self):
        self.make()
        other = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(other.close)
        other.execute("BEGIN IMMEDIATE")
        started = time.monotonic()
        db = ledger_open.open_rw(self.path, timeout=30)
        self.addCleanup(db.close)
        self.assertLess(time.monotonic() - started, 5)                # never the 30 s busy timeout
        self.assertEqual(ledger_open.write_state(db), "inconclusive")
        self.assertEqual(db.ledger_opens, 1)
        self.assertIsNone(db.ledger_unwritable)
        self.assertEqual(ledger_open.EVENTS, [])
        self.assertEqual(db.execute("PRAGMA busy_timeout").fetchone()[0], 30000)     # the caller's timeout is back
        other.execute("ROLLBACK")
        db.execute("INSERT INTO t VALUES (2)")
        db.commit()

    def test_memory_is_passed_through(self):
        db = ledger_open.open_rw(":memory:")
        db.execute("CREATE TABLE t (x)")
        db.execute("INSERT INTO t VALUES (1)")
        self.assertEqual(ledger_open.EVENTS, [])

    @unittest.skipIf(os.geteuid() == 0, NOT_ROOT)
    def test_a_write_connection_whose_wal_is_read_only_names_the_file_and_never_a_bare_error(self):
        # A REAL read-only WAL handle: reads work, the write is refused - the shape of all six crashes.
        self.wal_without_the_write_bit()
        raw = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(raw.close)
        self.assertEqual(raw.execute("SELECT count(*) FROM t").fetchone()[0], 1)
        with self.assertRaises(sqlite3.OperationalError) as bare:
            raw.execute("BEGIN IMMEDIATE")
        self.assertEqual(str(bare.exception), "attempt to write a readonly database")   # what the run log held

        db = ledger_open.open_rw(self.path, opener="a test", timeout=30, isolation_level=None)
        self.addCleanup(db.close)
        self.assertEqual(db.execute("SELECT count(*) FROM t").fetchone()[0], 1)          # an open that only reads works
        self.assertEqual(db.ledger_opens, ledger_open.RW_OPEN_ATTEMPTS)                  # bounded, then it gives up
        for write in (lambda: db.execute("BEGIN IMMEDIATE"), lambda: db.execute("INSERT INTO t VALUES (2)")):
            with self.assertRaises(ledger_open.LedgerNotWritableError) as caught:
                write()
            exc = caught.exception
            self.assertNotIsInstance(exc, ledger_open.ReadOnlyConnectionWriteError)     # the caller did hold a writer
            self.assertEqual(exc.reason, ledger_open.PERMISSION)
            self.assertIn("ledger.sqlite3-wal", str(exc))
            self.assertIn(f"uid {os.geteuid()} may not write", str(exc))
            self.assertIn("mode 444", str(exc))
            self.assertIn("wal=", str(exc))                           # the owners and modes read at open
            self.assertIn("attempt to write a readonly database", str(exc))   # SQLite's own words are kept
            self.assertIsInstance(exc.__cause__, sqlite3.OperationalError)
        self.assertEqual(len(ledger_open.EVENTS), 1)
        self.assertIn(f"after {ledger_open.RW_OPEN_ATTEMPTS} open(s) and stays so", ledger_open.EVENTS[0])
        self.assertIn("permission", ledger_open.EVENTS[0])

    @unittest.skipIf(os.geteuid() == 0, NOT_ROOT)
    def test_a_writer_handed_the_read_only_fallback_is_reopened_and_says_so(self):
        # Nothing is faked: the first open really is read-only, and SQLite really repairs the file on it.
        self.wal_without_the_write_bit(empty=True)
        raw = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(raw.close)
        with self.assertRaises(sqlite3.OperationalError) as bare:
            raw.execute("BEGIN IMMEDIATE")                # one writer dies, bare - what a tick did
        self.assertEqual(str(bare.exception), "attempt to write a readonly database")
        raw.close()

        os.chmod(self.path + "-wal", 0o444)               # the reader re-created the file again
        said = []
        with mock.patch.object(ledger_open, "RW_REOPEN_SLEEP_S", 0), \
             mock.patch.object(ledger_open, "EVENT_SINK", said.append):
            db = ledger_open.open_rw(self.path, opener="a test", timeout=30, isolation_level=None)
        self.addCleanup(db.close)
        self.assertEqual(db.ledger_opens, 2)
        self.assertIsNone(db.ledger_unwritable)
        db.execute("BEGIN IMMEDIATE")                     # the statement three of the six crashes died on
        db.execute("INSERT INTO t VALUES (2)")
        db.execute("COMMIT")
        self.assertEqual(db.execute("SELECT count(*) FROM t").fetchone()[0], 2)
        self.assertEqual(len(said), 1)                    # reported once, never silently
        self.assertIn("gave this writer a read-only connection", said[0])
        self.assertIn("reopened writable on open 2 of 3", said[0])
        self.assertIn("ledger.sqlite3-wal", said[0])
        self.assertIn("wal=", said[0])                    # with the owners and modes read BEFORE the open repaired them

    def test_a_reopen_is_only_made_where_it_can_differ(self):
        can = ledger_open._reopen_can_help
        self.assertTrue(can(facts()))                                              # node-8: root
        self.assertTrue(can(facts(euid=1000, groups=(1000,), db=(1000, 1000, 0o640))))   # the WAL files' owner
        self.assertFalse(can(facts(euid=1001, groups=(1000,), db=(0, 1000, 0o660))))     # neither: nothing changes
        self.assertFalse(can(facts(fs_read_only=True)))
        self.assertFalse(can(facts(euid=1000, groups=(1000,))))                    # may not write the database itself

    @unittest.skipIf(os.geteuid() == 0, NOT_ROOT)
    def test_a_database_file_without_the_write_bit_is_named(self):
        # BEGIN IMMEDIATE does not see this one (SQLite answers OK and fails the INSERT), so the mode is read.
        self.make(wal=False)
        os.chmod(self.path, 0o444)
        db = ledger_open.open_rw(self.path, timeout=30)
        self.addCleanup(db.close)
        self.assertEqual(db.ledger_opens, 1)
        with self.assertRaises(ledger_open.LedgerNotWritableError) as caught:
            db.execute("INSERT INTO t VALUES (2)")
        self.assertEqual(caught.exception.reason, ledger_open.PERMISSION)
        self.assertIn("may not write ledger.sqlite3 ", str(caught.exception))
        self.assertIn("mode 444", str(caught.exception))

    @unittest.skipIf(os.geteuid() == 0, NOT_ROOT)
    def test_the_decider_ledger_and_the_verify_ledger_both_use_the_write_opener(self):
        ledger = Ledger(self.path)
        self.addCleanup(ledger.close)
        self.assertIsInstance(ledger.db, ledger_open.LedgerConnection)
        self.assertEqual(ledger.db.ledger_opener, "credit_review.ledger.Ledger")
        vdb = verify_ledger.connect(str(self.dir / "verify.sqlite3"))
        self.addCleanup(vdb.close)
        self.assertIsInstance(vdb, ledger_open.LedgerConnection)
        self.assertFalse(vdb.ledger_read_only)
        self.assertEqual(vdb.ledger_opener, "verify_ledger.connect")
        ledger.close()
        vdb.close()
        # the decider's crash: reads fine, then the first INSERT of the run is refused
        self.path = str(self.dir / "decider.sqlite3")
        self.wal_without_the_write_bit()
        with self.assertRaises(ledger_open.LedgerNotWritableError) as caught:
            Ledger(self.path)                                         # its CREATE TABLE IF NOT EXISTS + commit
        self.assertIn("credit_review.ledger.Ledger", str(caught.exception))
        self.assertIn("decider.sqlite3-wal", str(caught.exception))


def facts(*, euid=0, groups=(0,), directory=(0, 1000, 0o1770), db=(0, 1000, 0o640), wal=(1000, 1000, 0o640),
          shm=(1000, 1000, 0o640), protected_regular=2, fs_read_only=False):
    def ff(t):
        return None if t is None else ledger_open.FileFacts(*t)
    return ledger_open.Facts(path="/var/lib/hydra/credit-review/ledger.sqlite3", euid=euid, groups=frozenset(groups),
                             directory=ff(directory), db=ff(db), wal=ff(wal), shm=ff(shm),
                             protected_regular=protected_regular, fs_read_only=fs_read_only,
                             taken_at="2026-11-13T04:11:21Z")


class ClassifyTests(unittest.TestCase):
    """The reason, from the owners and modes alone. The default fixture is node-8 at 2026-11-13T04:11:21Z, sampled
    live: `shm=1000:1000:640 wal=1000:1000:640` in a `0:1000 1770` directory, root opening."""

    def test_node8_the_exporters_wal_in_the_sticky_directory(self):
        reason, why = ledger_open.classify(facts())
        self.assertEqual(reason, ledger_open.STICKY_DIRECTORY)
        self.assertIn("ledger.sqlite3-wal was created by uid 1000", why)
        self.assertIn("sticky (mode 1770, owner 0)", why)
        self.assertIn("fs.protected_regular=2", why)
        self.assertIn("uid 0 included", why)

    def test_only_the_shm_left_to_the_reader_is_still_named(self):
        reason, why = ledger_open.classify(facts(wal=(0, 1000, 0o640)))
        self.assertEqual(reason, ledger_open.STICKY_DIRECTORY)
        self.assertIn("ledger.sqlite3-shm was created by uid 1000", why)

    def test_the_kernel_rule_is_the_whole_rule(self):
        reader, directory = ledger_open.FileFacts(1000, 1000, 0o640), ledger_open.FileFacts(0, 1000, 0o1770)
        refuses = ledger_open.sticky_refuses
        self.assertTrue(refuses(directory, reader, 0, 2))
        self.assertFalse(refuses(directory, reader, 0, 1))            # group-writable needs level 2
        self.assertFalse(refuses(directory, reader, 0, 0))            # the sysctl is off
        self.assertFalse(refuses(directory, reader, 0, None))         # unmeasured is not asserted as the cause
        self.assertFalse(refuses(directory, reader, 1000, 2))         # the file's own owner may open it
        self.assertFalse(refuses(ledger_open.FileFacts(0, 1000, 0o770), reader, 0, 2))      # no sticky bit: the control
        self.assertFalse(refuses(directory, ledger_open.FileFacts(0, 1000, 0o640), 1001, 2))  # the directory owner's file
        self.assertTrue(refuses(ledger_open.FileFacts(0, 0, 0o1777), reader, 0, 1))         # world-writable: level 1
        self.assertFalse(refuses(ledger_open.FileFacts(0, 1000, 0o1750), reader, 0, 2))     # not group-writable
        self.assertFalse(refuses(directory, None, 0, 2))

    def test_without_the_sticky_bit_or_the_sysctl_root_has_no_known_cause(self):
        self.assertEqual(ledger_open.classify(facts(directory=(0, 1000, 0o770)))[0], ledger_open.UNKNOWN)
        self.assertEqual(ledger_open.classify(facts(protected_regular=0))[0], ledger_open.UNKNOWN)

    def test_a_group_member_who_may_only_read_the_ledger(self):
        # the first candidate in the brief: uid in group 1000, database `-rw-r----- root 1000`
        reason, why = ledger_open.classify(facts(euid=1000, groups=(1000,), wal=None, shm=None))
        self.assertEqual(reason, ledger_open.PERMISSION)
        self.assertIn("uid 1000 may not write ledger.sqlite3 (owner 0, group 1000, mode 640)", why)

    def test_a_wal_this_uid_may_only_read(self):
        reason, why = ledger_open.classify(facts(euid=1001, groups=(1000,), directory=(0, 1000, 0o770),
                                                 db=(0, 1000, 0o660), wal=(0, 1000, 0o640), shm=(0, 1000, 0o660)))
        self.assertEqual(reason, ledger_open.PERMISSION)
        self.assertIn("ledger.sqlite3-wal (owner 0, group 1000, mode 640)", why)

    def test_a_read_only_filesystem_outranks_the_modes(self):
        reason, why = ledger_open.classify(facts(fs_read_only=True))
        self.assertEqual(reason, ledger_open.READ_ONLY_FILESYSTEM)
        self.assertIn("mounted read-only", why)

    def test_read_only_mode_is_its_own_reason(self):
        reason, why = ledger_open.classify(facts(), read_only_mode=True)
        self.assertEqual(reason, ledger_open.READ_ONLY_MODE)
        self.assertIn("reader", why)

    def test_no_facts_is_unknown_never_a_guess(self):
        self.assertEqual(ledger_open.classify(None)[0], ledger_open.UNKNOWN)

    def test_the_facts_line_carries_what_was_read(self):
        line = facts().render()
        self.assertIn("uid=0 dir=0:1000:1770 db=0:1000:640 wal=1000:1000:640 shm=1000:1000:640", line)
        self.assertIn("fs.protected_regular=2", line)
        self.assertIn("fs.protected_regular=unreadable", facts(protected_regular=None).render())
        self.assertIn("wal=absent", facts(wal=None).render())

    def test_snapshot_only_stats(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ledger.sqlite3")
            got = ledger_open.snapshot(path)
            self.assertEqual(os.listdir(d), [])
            self.assertIsNone(got.db)
            self.assertEqual(got.euid, os.geteuid())
            self.assertIsNotNone(got.directory)


class ReadOnlyProcessTests(Base):
    """Acceptance 3: a dry run followed by a write in one process cannot silently become read-only."""

    def write(self, db) -> None:
        db.execute(f'DELETE FROM "{verify_ledger.TABLES[0]}"')

    def test_the_flag_is_scoped_to_its_block(self):
        verify_ledger.connect(self.path).close()
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)
        with verify_ledger.read_only_process():
            self.assertTrue(verify_ledger.READ_ONLY_PROCESS)
            db = verify_ledger.connect(self.path)                      # the WRITE opener, inside a read-only run
            self.addCleanup(db.close)
            self.assertTrue(db.ledger_read_only)
            with self.assertRaises(ledger_open.ReadOnlyConnectionWriteError):
                self.write(db)
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)
        after = verify_ledger.connect(self.path)                       # the write that follows the dry run
        self.addCleanup(after.close)
        self.assertFalse(after.ledger_read_only)
        self.write(after)

    def test_an_exception_does_not_leave_the_process_read_only(self):
        verify_ledger.connect(self.path).close()
        with self.assertRaises(RuntimeError), verify_ledger.read_only_process():
            raise RuntimeError("the dry run died")
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)
        db = verify_ledger.connect(self.path)
        self.addCleanup(db.close)
        self.write(db)

    def test_blocks_nest(self):
        with verify_ledger.read_only_process():
            with verify_ledger.read_only_process():
                self.assertTrue(verify_ledger.READ_ONLY_PROCESS)
            self.assertTrue(verify_ledger.READ_ONLY_PROCESS)            # the inner exit does not open the outer one
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)

    def test_a_read_only_block_never_creates_a_missing_ledger(self):
        with verify_ledger.read_only_process(), self.assertRaises(verify_ledger.ReadOnlyLedgerError):
            verify_ledger.connect(self.path)
        self.assertFalse(os.path.exists(self.path))


class CliTests(Base):
    def cli(self):
        spec = importlib.util.spec_from_file_location("credit_review_cli_ledger_open", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        return cli

    def run_cli(self, cli, *argv, kill: bool):
        ks = self.dir / "credit-ops-notes.disabled"
        if kill:
            ks.write_text("")
        out = io.StringIO()
        with mock.patch.object(cli, "CREDIT_OPS_NOTES_KILL_SWITCH", ks), \
             mock.patch.object(runner, "LOG_PATH", str(self.dir / "run.log")), \
             contextlib.redirect_stdout(out):
            rc = cli.main(["--ledger", self.path, *argv])
        return rc, out.getvalue()

    UVN = ("uvn-status", "--list", "unused.json", "--segment", "paid", "--mode", "dry-run")

    def test_a_kill_switch_dry_run_then_a_write_in_the_same_process(self):
        cli = self.cli()
        verify_ledger.connect(self.path).close()
        seen = {}

        def dry_run(args):
            seen["flag"] = verify_ledger.READ_ONLY_PROCESS
            db = verify_ledger.connect(self.path)
            try:
                seen["read_only"] = db.ledger_read_only
                with self.assertRaises(ledger_open.ReadOnlyConnectionWriteError):
                    db.execute(f'DELETE FROM "{verify_ledger.TABLES[0]}"')
            finally:
                db.close()
            return 0

        with mock.patch.object(cli, "_uvn_status", dry_run):
            rc, out = self.run_cli(cli, *self.UVN, kill=True)
        self.assertEqual(rc, 0, out)
        self.assertIn("dry run only", out)
        self.assertEqual(seen, {"flag": True, "read_only": True})       # the dry run itself WAS read-only
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)               # and it ended with the run
        db = verify_ledger.connect(self.path)                           # what used to come back mode=ro
        self.addCleanup(db.close)
        self.assertFalse(db.ledger_read_only)
        db.execute(f'DELETE FROM "{verify_ledger.TABLES[0]}"')

    def test_a_dry_run_that_crashes_does_not_leave_the_process_read_only(self):
        cli = self.cli()
        verify_ledger.connect(self.path).close()

        def dies(args):
            raise ValueError("boom")

        with mock.patch.object(cli, "_uvn_status", dies):
            rc, out = self.run_cli(cli, *self.UVN, kill=True)
        self.assertEqual(rc, 1, out)
        self.assertFalse(verify_ledger.READ_ONLY_PROCESS)

    def test_without_the_kill_switch_the_run_is_not_read_only(self):
        cli = self.cli()
        seen = {}

        def run(args):
            seen["flag"] = verify_ledger.READ_ONLY_PROCESS
            return 0

        with mock.patch.object(cli, "_uvn_status", run):
            rc, out = self.run_cli(cli, *self.UVN, kill=False)
        self.assertEqual((rc, seen), (0, {"flag": False}), out)

    def test_a_refused_write_is_one_line_that_names_the_reason(self):
        cli = self.cli()

        def refused(args):
            raise ledger_open.LedgerNotWritableError(
                "cannot write ledger /x: permission_sticky_directory - ledger.sqlite3-wal was created by uid 1000",
                reason=ledger_open.STICKY_DIRECTORY, why="ledger.sqlite3-wal was created by uid 1000", path="/x")

        with mock.patch.object(cli, "_uvn_status", refused):
            rc, out = self.run_cli(cli, *self.UVN, kill=False)
        self.assertEqual(rc, 1, out)                                    # the tick's handling of a failed step is unchanged
        self.assertEqual(len(out.strip().splitlines()), 1, out)
        self.assertIn("uvn-status stopped: it could not write its ledger (permission_sticky_directory)", out)
        self.assertIn("ledger.sqlite3-wal was created by uid 1000", out)
        self.assertNotIn("internal error", out)
        log = (self.dir / "run.log").read_text()
        self.assertIn("crash: Traceback", log)                          # the traceback is still kept
        self.assertIn("LedgerNotWritableError", log)

    def test_a_reopen_is_written_to_the_run_log(self):
        cli = self.cli()

        def reopened(args):
            ledger_open._event("ledger-open: /x gave this writer a read-only connection; reopened writable")
            return 0

        with mock.patch.object(cli, "_uvn_status", reopened), mock.patch.object(ledger_open, "EVENT_SINK", None):
            rc, out = self.run_cli(cli, *self.UVN, kill=False)
            self.assertEqual(rc, 0, out)
        self.assertIn("ledger-open: /x gave this writer a read-only connection", (self.dir / "run.log").read_text())
        self.assertNotIn("ledger-open", out)                            # the log, never the cron's stdout


class OneCopyTests(unittest.TestCase):
    """verify_ledger.py is run as a file with no package (`python3 -I`, deploy.sh), so it loads ledger_open by path.
    Whichever way the module is reached, a process holds one copy - or `except LedgerNotWritableError` misses."""

    def test_the_package_import_and_the_loader_are_the_same_module(self):
        self.assertIs(verify_ledger.ledger_open(), ledger_open)
        self.assertIs(sys.modules["credit_review.ledger_open"], sys.modules[ledger_open.SHARED_NAME])

    def run_py(self, code: str, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", "-c", code, str(ROOT / "scripts"), *args],
                              capture_output=True, text=True, timeout=120)

    def test_either_order_gives_one_copy(self):
        orders = {
            "loader first": ("import verify_ledger\nfirst = verify_ledger.ledger_open()\n"
                             "sys.path.insert(0, sys.argv[1])\nfrom credit_review import ledger_open as second\n"),
            "package first": ("sys.path.insert(0, sys.argv[1])\nfrom credit_review import ledger_open as first\n"
                              "import verify_ledger\nsecond = verify_ledger.ledger_open()\n"),
        }
        for name, body in orders.items():
            with self.subTest(name):
                code = ("import sys\nsys.path.insert(0, sys.argv[1] + '/credit_review')\n" + body +
                        "assert first is second, (first, second)\n"
                        "assert first.LedgerNotWritableError is second.LedgerNotWritableError\nprint('one')\n")
                got = self.run_py(code)
                self.assertEqual((got.returncode, got.stdout.strip()), (0, "one"), got.stderr)

    def test_the_real_entrypoint_runs_as_a_file_with_no_package(self):
        # deploy.sh: /usr/bin/python3 -I /opt/hydra/scripts/credit_review/verify_ledger.py --db ... migrate
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ledger.sqlite3")
            script = str(ROOT / "scripts" / "credit_review" / "verify_ledger.py")
            got = subprocess.run([sys.executable, "-I", script, "--db", path, "migrate"],
                                 capture_output=True, text=True, timeout=120)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            tables = {n for (n,) in sqlite3.connect(path).execute("SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertTrue(set(verify_ledger.TABLES) <= tables)


if __name__ == "__main__":
    unittest.main()
