"""verify-outbound-migration-race-m1 (Fable 2026-11-05 12:2xZ) + spec-deploy-lock-deferral-m1 addendum.

At 11:49:02Z the live outbound tick migrated verify_messages (approval_id, approver_kind, template_sha256) while another
lane ran a read-only check on the same ledger: 89 FAILED "verify ledger needs a migration", rc=1, and the tick stopped
with zero sends. The columns were there seconds later and the re-run was clean - a RACE, not a stale deploy.

Three parts, each pinned here:
  1. the migration is ATOMIC (one BEGIN IMMEDIATE), so a reader sees pre- or post-, never a partial schema;
  2. the tick migrates ONCE before it takes its lock (pinned in credit-verify-outbound.bats, the ordering arm);
  3. connect_ro() retries the ADDITIVE case a bounded number of times - and a genuinely stale ledger still raises.

The Trino half of the same incident (14:25:53Z: "under too much load ... please retry") is pinned at the bottom: a
transient upstream failure is a TYPED error with its own exit code, never a bare RuntimeError that stops the run.
"""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import importlib.util
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import verify_ledger, verify_notify  # noqa: E402

# the three columns the 11:49:02Z migration was adding
RACE_COLUMNS = ("approval_id", "approver_kind", "template_sha256")


def old_ledger(path: Path) -> None:
    """A ledger from before the race columns: verify_messages exists, the three columns do not."""
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, kind TEXT, "
               "status TEXT, user_key TEXT, day TEXT)")
    db.commit()
    db.close()


def columns(path: Path) -> set[str]:
    db = sqlite3.connect(path)
    try:
        return {str(r[1]) for r in db.execute("PRAGMA table_info(verify_messages)")}
    finally:
        db.close()


class _Boom:
    """A connection proxy that fails on the Nth ALTER - the shape of a migration that dies half way."""

    def __init__(self, db: sqlite3.Connection, fail_after: int):
        self.db, self.fail_after, self.alters = db, fail_after, 0

    def execute(self, sql: str, *args):
        if sql.startswith("ALTER TABLE"):
            self.alters += 1
            if self.alters > self.fail_after:
                raise RuntimeError("boom: the migration died half way")
        return self.db.execute(sql, *args)


class _Recorder:
    """A connection proxy that records the SQL it is asked to run, in order."""

    def __init__(self, db: sqlite3.Connection):
        self.db, self.sql = db, []

    def execute(self, sql: str, *args):
        self.sql.append(sql)
        return self.db.execute(sql, *args)


class MigrationAtomicityTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="verify-ledger-race-"))
        self.path = self.dir / "ledger.sqlite3"
        old_ledger(self.path)

    def test_the_whole_column_set_is_one_transaction_so_a_failure_rolls_every_alter_back(self):
        # part 1: without BEGIN IMMEDIATE each ALTER commits on its own and a reader between two of them sees a PARTIAL
        # schema - exactly the 89 FAILED. With it, a migration that dies half way leaves the ledger UNCHANGED.
        # a RAW connection: connect() would migrate the ledger before _migrate is ever reached
        db = sqlite3.connect(self.path, isolation_level=None)
        try:
            before = columns(self.path)
            with self.assertRaises(RuntimeError):
                verify_ledger._migrate(_Boom(db, fail_after=1))
            self.assertEqual(columns(self.path), before, "a failed migration must roll back every ALTER")
        finally:
            db.close()

    def test_a_complete_migration_adds_every_column(self):
        db = verify_ledger.connect(self.path)
        db.close()
        self.assertTrue(set(RACE_COLUMNS) <= columns(self.path))

    def test_the_gap_is_derived_under_the_write_lock_not_before_it(self):
        """QA #1799 r10: deriving the ALTER list BEFORE BEGIN IMMEDIATE let two migrators read the same pre-migration
        schema; the loser then locked after the winner had committed, executed its stale list and died on "duplicate
        column name" - which the pre-tick path turns into a killed tick over an already-current ledger.

        Pinned by ORDER, not by luck: the first PRAGMA table_info must come AFTER BEGIN IMMEDIATE. A thread-race test
        would only fail sometimes; this fails every time the derivation moves back out of the transaction."""
        db = sqlite3.connect(self.path, isolation_level=None)
        try:
            db.executescript(verify_ledger.SCHEMA)      # what connect() does before _migrate: the tables exist
            seen = _Recorder(db)
            verify_ledger._migrate(seen)
        finally:
            db.close()
        self.assertIn("BEGIN IMMEDIATE", seen.sql, "the migration must take the write lock")
        first_pragma = next(i for i, s in enumerate(seen.sql) if s.startswith("PRAGMA table_info"))
        self.assertLess(seen.sql.index("BEGIN IMMEDIATE"), first_pragma,
                        "the gap must be derived INSIDE the transaction: a stale ALTER list is a duplicate-column kill")
        self.assertTrue(set(RACE_COLUMNS) <= columns(self.path))

    def test_concurrent_migrators_on_the_same_old_ledger_all_succeed(self):
        """The shape QA asked for: N processes opening the same stale ledger at once. Every one must return a usable
        connection and the ledger must end up current - never a duplicate-column error, never a partial schema."""
        errors: list[BaseException] = []
        start = threading.Barrier(8)

        def migrate():
            try:
                start.wait(timeout=10)
                verify_ledger.connect(self.path).close()
            except BaseException as exc:            # noqa: BLE001 - the assertion below reports it
                errors.append(exc)

        threads = [threading.Thread(target=migrate) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=30)
        self.assertEqual(errors, [], "a concurrent migrator must never die on a duplicate column")
        self.assertTrue(set(RACE_COLUMNS) <= columns(self.path))


class ReaderToleranceTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="verify-ledger-ro-"))
        self.path = self.dir / "ledger.sqlite3"
        old_ledger(self.path)
        self._sleep = verify_ledger.RO_RETRY_SLEEP_S
        verify_ledger.RO_RETRY_SLEEP_S = 0.1           # the window is 3 attempts; the test does not wait 4 s

    def tearDown(self):
        verify_ledger.RO_RETRY_SLEEP_S = self._sleep

    def test_a_reader_that_lands_inside_a_live_migration_waits_it_out_instead_of_reporting_89_failed(self):
        # part 3: the 11:49:02Z shape. The writer migrates 0.1 s after the reader starts; the reader must return a
        # usable connection, never a partial-schema refusal.
        #
        # The window here is 2 x 1.0 s, not setUp's 2 x 0.1 s. The production ledger is in WAL mode, where a reader
        # is never held behind a writer's lock: what carries the reader past a live migration is connect_ro's retry
        # window and nothing else. On a rollback-journal ledger the reader's second look BLOCKED on the migrator's
        # lock until it finished, which is the only reason a 0.2 s window ever covered a 0.2 s migration. The reader
        # returns as soon as the schema is whole, so this costs one sleep, not the window.
        verify_ledger.RO_RETRY_SLEEP_S = 1.0

        def migrate_soon():
            time.sleep(0.05)
            verify_ledger.connect(self.path).close()

        t = threading.Thread(target=migrate_soon)
        t.start()
        try:
            db = verify_ledger.connect_ro(self.path)
            db.close()
        finally:
            t.join()

    def test_a_genuinely_stale_ledger_is_still_loud_after_the_window(self):
        # no migration is running: the tolerance is for a RACE, never for a deploy gap
        with self.assertRaises(verify_ledger.ReadOnlyLedgerError) as ctx:
            verify_ledger.connect_ro(self.path)
        self.assertIn("needs a migration", str(ctx.exception))

    def test_a_corrupt_file_raises_immediately_and_is_never_retried(self):
        bad = self.dir / "corrupt.sqlite3"
        bad.write_bytes(b"this is not a sqlite database at all" * 10)
        t0 = time.monotonic()
        with self.assertRaises(verify_ledger.ReadOnlyLedgerError):
            verify_ledger.connect_ro(bad)
        self.assertLess(time.monotonic() - t0, 0.5, "a corrupt file is not a race: it must not wait the window")

    def test_a_current_ledger_is_unchanged_no_added_latency(self):
        verify_ledger.connect(self.path).close()       # migrate it once
        t0 = time.monotonic()
        db = verify_ledger.connect_ro(self.path)
        db.close()
        self.assertLess(time.monotonic() - t0, 0.5)


class TrinoTransientTests(unittest.TestCase):
    """spec-deploy-lock-deferral-m1 addendum: Trino's own "retry in a few minutes" is a TYPED, retryable failure."""

    def _trino(self, stderr: str, rc: int = 1):
        d = Path(tempfile.mkdtemp(prefix="trino-stub-"))
        cmd = d / "trino.sh"
        cmd.write_text(f"#!/bin/sh\nprintf '%s' {stderr!r} >&2\nexit {rc}\n")
        cmd.chmod(0o755)
        return cmd

    def test_the_1425z_stderr_is_transient(self):
        # the exact words from /var/lib/hydra/credit-review/run.log at 14:25:53Z
        stderr = (" be under too much load. This is probably a transient issue, so please retry your query in a few "
                  "minutes. (updating task http://10.240.79.188:8080/v1/task/20261105_142446_39530_4frni.0.0.0 - 1")
        self.assertTrue(verify_notify.trino_transient(stderr))
        with self.assertRaises(verify_notify.TrinoTransientError):
            verify_notify.trino("SELECT 1", cmd=str(self._trino(stderr)))

    def test_a_real_query_failure_stays_terminal(self):
        # a SQL error, a missing table, an auth failure: still a bare RuntimeError, never retried, never deferred
        stderr = "line 1:8: Column 'nope' cannot be resolved"
        self.assertFalse(verify_notify.trino_transient(stderr))
        with self.assertRaises(RuntimeError) as ctx:
            verify_notify.trino("SELECT nope", cmd=str(self._trino(stderr)))
        self.assertNotIsInstance(ctx.exception, verify_notify.TrinoTransientError)

    # [key=trino-eof-transient] the 04:00Z auto-kill: a TRUNCATED HTTP RESPONSE is transient, and a bare "eof"
    # substring is NOT the way to say so (it would swallow "column eof_marker cannot be resolved").
    TRANSIENT_STDERR = (
        # the exact words from the 04:00Z uvn-status-paid apply
        'curl: (18) transfer closed with outstanding read data remaining: ...&error=1&output=1": EOF',
        "read timed out",
        "Connection reset by peer",
        'curl: (18) transfer closed with outstanding read data remaining: EOF',
    )
    TERMINAL_STDERR = (
        "Table 'hive.x' does not exist",
        "Access Denied: User cannot execute query",
        "line 1:8: Column 'foo' cannot be resolved",
        "syntax error at or near",
        "line 1:8: Column 'eof_marker' cannot be resolved",
        # the quoted-identifier trap: EOF as a SQL identifier must never look like a truncated transport
        "line 1:8: Column 'EOF' cannot be resolved",
    )

    def test_a_truncated_response_is_transient(self):
        for stderr in self.TRANSIENT_STDERR:
            with self.subTest(stderr=stderr):
                self.assertTrue(verify_notify.trino_transient(stderr))
                with self.assertRaises(verify_notify.TrinoTransientError):
                    verify_notify.trino("SELECT 1", cmd=str(self._trino(stderr)))

    def test_a_real_sql_error_is_still_terminal(self):
        for stderr in self.TERMINAL_STDERR:
            with self.subTest(stderr=stderr):
                self.assertFalse(verify_notify.trino_transient(stderr))
                with self.assertRaises(RuntimeError) as ctx:
                    verify_notify.trino("SELECT 1", cmd=str(self._trino(stderr)))
                self.assertNotIsInstance(ctx.exception, verify_notify.TrinoTransientError)

    def test_eof_is_matched_as_a_token_never_as_a_prefix(self):
        # the whole reason the marker tuple does not carry a bare "eof"
        self.assertTrue(verify_notify.trino_transient('...&output=1": EOF'))
        self.assertTrue(verify_notify.trino_transient("EOF"))
        self.assertFalse(verify_notify.trino_transient("column eof_marker cannot be resolved"))
        self.assertFalse(verify_notify.trino_transient("eof_marker"))
        # a quoted identifier named EOF is a permanent SQL error, not a truncated transport; the
        # transient and terminal cases live in ONE test so nobody can widen the matcher without
        # breaking the lookalike (firstmate, 2026-11-07)
        self.assertFalse(verify_notify.trino_transient("line 1:8: Column 'EOF' cannot be resolved"))
        self.assertFalse(verify_notify.trino_transient("line 1:8: Column 'EOF' does not exist"))
        self.assertFalse(verify_notify.trino_transient("line 1:8: Column 'EOF' is not a valid identifier"))

    def test_a_successful_query_is_unchanged(self):
        d = Path(tempfile.mkdtemp(prefix="trino-ok-"))
        cmd = d / "trino.sh"
        cmd.write_text('#!/bin/sh\nprintf \'"a","b"\\n"1","2"\\n\'\n')
        cmd.chmod(0o755)
        self.assertEqual(verify_notify.trino("SELECT 1", cmd=str(cmd)), [["a", "b"], ["1", "2"]])


class RunnerExitCodeTests(unittest.TestCase):
    """The runner maps the typed error to its own exit code, so the tick can tell a transient from a real failure."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("credit_review_cli", ROOT / "scripts" / "credit-review.py")
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)

    def test_the_transient_exit_code_is_distinct_from_a_failure(self):
        self.assertEqual(self.cli.TRANSIENT_RC, 4)
        self.assertNotIn(self.cli.TRANSIENT_RC, (0, 1, 2, 3))

    def test_a_transient_inside_a_run_exits_4_not_1(self):
        import argparse

        def boom(_args):
            raise verify_notify.TrinoTransientError("trino transient: under too much load")

        args = argparse.Namespace(cmd="uvn-status", mode="dry-run", fn=boom, max_users=1, max_users_default=1)
        orig = self.cli.parser
        self.cli.parser = lambda: type("P", (), {"parse_args": staticmethod(lambda _a=None: args)})()
        try:
            self.assertEqual(self.cli.main([]), 4)
        finally:
            self.cli.parser = orig


if __name__ == "__main__":
    unittest.main()
