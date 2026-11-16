"""Caroline's send ledger: the writer (credit_review.verify_ledger, called by
intercom-verify-request.sh) and credit-retro's reader (credit_retro.waves.already_engaged,
used by the take-back gate) agree on verify_messages (firstmate 041, Fable option a).

- `verify_ledger.py migrate` creates the verify tables in an EXISTING shared ledger (the
  decider's tables live in the same file) without touching anything else, idempotently.
- The reader's required columns are exactly what the writer's schema provides.
- What the writer records (a sent note, a proof tag) is what the reader sees.

Two suites are folded in here rather than wired as their own files (lane verif-sender-cluster-scale-k1): a new
`python3 scripts/tests/<file>.py` line in pr-validate.yml puts that workflow file in the PR's changed set, and the
`Rebase staleness check` then fails on any head that is behind a `main` which moved pr-validate.yml -- which is most
of them, since nearly every lane appends a line there.

Suite one, `OpenerTests` / `PinnedPathTests` / `RealEntrypointTests`: An empty send record answers "never messaged" for every person. Before this rule the write opener created one
wherever it was pointed: `pending` against a missing path exited 0 with daily_cap false and user_done "" and left a
73,728-byte ledger with 0 rows. A sender on a host without the real ledger would have messaged everyone again.

- At verify_ledger.PRODUCTION_PATH, connect() raises LedgerAbsentError for a missing file and for a file with no
  verify_messages table, and writes nothing.
- Every other path (a scratch ledger, a test) is created on open exactly as before.
- `init` is the one explicit creation, and it never touches a ledger that has a send record. An existing file that
  holds other tables but no send record is refused (a restored pre-send-record backup would otherwise answer "never
  messaged" for everyone); who ran it goes to stderr.
- `ensure_schema`, the creator every caller with its own handle funnels through, carries the same refusal.
- The CLI cases run the real entrypoint (`python3 -I verify_ledger.py`) in a mirror of scripts/credit_review with
  that ONE literal rewritten, because the real production path cannot be written from a test.

Suite two, `ReadbackTests`: `verify_ledger._same_user()` is a predicate against a candidate identity pair, not an equivalence relation over
rows, so a pairwise grouping of rows by one identity column reports "no duplicates" for a person `capped()` refuses.
The case that made this concrete: a note stamped with the user id and an older note with no account id whose request
the decider recorded for the same user id."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_retro import waves  # noqa: E402
from credit_review import verify_ledger  # noqa: E402

HELPER = ROOT / "scripts" / "credit_review" / "verify_ledger.py"


def migrate(path: Path) -> dict:
    res = subprocess.run([sys.executable, "-I", str(HELPER), "--db", str(path), "migrate"],
                         capture_output=True, text=True, timeout=60, check=False)
    assert res.returncode == 0, res.stderr
    return json.loads(res.stdout)


class LedgerContractTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="verify-ledger-contract-"))
        self.path = self.dir / "ledger.sqlite3"

    def test_reader_columns_are_in_the_writer_schema(self):
        ref = sqlite3.connect(":memory:")
        ref.executescript(verify_ledger.SCHEMA)
        cols = {str(r[1]) for r in ref.execute("PRAGMA table_info(verify_messages)")}
        ref.close()
        self.assertTrue(verify_ledger.READER_COLUMNS <= cols, verify_ledger.READER_COLUMNS - cols)

    def test_the_take_back_reader_refuses_a_ledger_without_the_table(self):
        # The node-8 state before this change: the shared ledger exists (decider tables
        # only) and the take-back gate cannot prove anyone safe, so it refuses.
        db = sqlite3.connect(self.path)
        db.execute("CREATE TABLE decisions (request_id TEXT, run_id TEXT)")
        db.commit()
        db.close()
        with self.assertRaises(SystemExit):
            waves.already_engaged(str(self.path))

    def test_migrate_creates_the_tables_in_a_shared_ledger_and_touches_nothing_else(self):
        db = sqlite3.connect(self.path)
        db.execute("CREATE TABLE decisions (request_id TEXT, run_id TEXT)")
        db.execute("INSERT INTO decisions VALUES ('r1', 'run-1')")
        db.commit()
        db.close()
        out = migrate(self.path)
        self.assertEqual(out["result"], "ok")
        self.assertEqual(set(out["tables"]), set(verify_ledger.TABLES))
        self.assertTrue(verify_ledger.READER_COLUMNS <= set(out["tables"]["verify_messages"]))
        again = migrate(self.path)  # idempotent
        self.assertEqual(again, out)
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT * FROM decisions").fetchall(), [("r1", "run-1")])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0], 0)
        db.close()
        # An empty, migrated ledger is readable: nobody engaged yet (not None, not a refusal).
        self.assertEqual(waves.already_engaged(str(self.path)), (set(), set(), set()))

    def test_migrate_upgrades_an_older_verify_messages_table(self):
        db = sqlite3.connect(self.path)
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT, kind TEXT, "
                   "status TEXT, user_key TEXT, day TEXT)")
        db.commit()
        db.close()
        with self.assertRaises(SystemExit):
            waves.already_engaged(str(self.path))
        migrate(self.path)
        self.assertEqual(waves.already_engaged(str(self.path)), (set(), set(), set()))

    def test_what_the_writer_records_is_what_the_reader_sees(self):
        db = verify_ledger.connect(str(self.path))
        c = verify_ledger.claim(db, campaign=waves.SEND_CAMPAIGN, user_key="jane@example.com", day="2026-10-18",
                                request_ids=["r1", "r2"], message_type="email", approved_by="U7RP6HKUZ",
                                approval_ref="ref")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="500")
        verify_ledger.mark_tagged(db, message_id="500", conversation_id="777", attachments=1)
        db.close()
        ids, proof_users, asked_users = waves.already_engaged(str(self.path))
        self.assertEqual((ids, proof_users, asked_users), ({"r1", "r2"}, {"jane@example.com"}, {"jane@example.com"}))


# --- Suite one: the production send ledger is never created by an open (lane verif-sender-cluster-scale-k1) ---

PKG = ROOT / "scripts" / "credit_review"
LITERAL = 'PRODUCTION_PATH = "/var/lib/hydra/credit-review/ledger.sqlite3"'
PENDING = ["pending", "--campaign", "uvn-status", "--user-key", "a@example.com", "--user-id", "4242",
           "--day", "2026-11-13", "--request-ids", "11111111-1111-4111-8111-111111111111"]

def tables(path: Path) -> set[str]:
    db = sqlite3.connect(path)
    try:
        return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    finally:
        db.close()

class Scratch(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.prod = self.tmp / "var" / "ledger.sqlite3"      # its parent does not exist either

class OpenerTests(Scratch):
    def setUp(self) -> None:
        super().setUp()
        patch = mock.patch.object(verify_ledger, "PRODUCTION_PATH", str(self.prod))
        patch.start()
        self.addCleanup(patch.stop)

    def test_a_missing_production_ledger_is_refused_and_nothing_is_created(self) -> None:
        with self.assertRaises(verify_ledger.LedgerAbsentError) as ctx:
            verify_ledger.connect(str(self.prod))
        self.assertIn("does not exist", str(ctx.exception))
        self.assertIn(" init", str(ctx.exception))
        self.assertFalse(self.prod.exists())
        self.assertFalse(self.prod.parent.exists())

    def test_a_file_without_the_send_record_is_refused_and_gains_no_table(self) -> None:
        # the decider shares the file: it can exist with the decider's tables and no verify_messages
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY)")
        db.commit()
        db.close()
        with self.assertRaises(verify_ledger.LedgerAbsentError) as ctx:
            verify_ledger.connect(str(self.prod))
        self.assertIn("has no verify_messages table", str(ctx.exception))
        self.assertEqual(tables(self.prod), {"decisions"})

    def test_a_symlink_to_the_production_ledger_is_the_production_ledger(self) -> None:
        link = self.tmp / "link.sqlite3"
        link.symlink_to(self.prod)
        with self.assertRaises(verify_ledger.LedgerAbsentError):
            verify_ledger.connect(str(link))
        self.assertFalse(self.prod.exists())

    def test_a_ledger_that_holds_the_send_record_opens_and_is_still_upgraded(self) -> None:
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT)")   # an old, narrow schema
        db.execute("INSERT INTO verify_messages (campaign) VALUES ('uvn-status')")
        db.commit()
        db.close()
        conn = verify_ledger.connect(str(self.prod))
        try:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0], 1)
            cols = {r[1] for r in conn.execute("PRAGMA table_info(verify_messages)")}
            self.assertIn("sent_at", cols)                    # _migrate still adds what is missing
        finally:
            conn.close()
        self.assertTrue(set(verify_ledger.TABLES) <= tables(self.prod))

    def test_a_scratch_path_is_created_on_open_as_before(self) -> None:
        scratch = self.tmp / "elsewhere" / "ledger.sqlite3"
        verify_ledger.connect(str(scratch)).close()
        self.assertIn("verify_messages", tables(scratch))
        verify_ledger.connect(":memory:").close()

    def test_the_error_is_not_one_a_tolerant_caller_already_swallows(self) -> None:
        self.assertFalse(issubclass(verify_ledger.LedgerAbsentError, verify_ledger.ReadOnlyLedgerError))
        self.assertFalse(issubclass(verify_ledger.LedgerAbsentError, sqlite3.Error))

    def test_a_read_only_process_still_gets_the_read_only_refusal(self) -> None:
        with verify_ledger.read_only_process():
            with self.assertRaises(verify_ledger.ReadOnlyLedgerError):
                verify_ledger.connect(str(self.prod))
        self.assertFalse(self.prod.exists())

    def test_ensure_schema_on_a_handle_to_the_production_ledger_starts_no_send_record(self) -> None:
        # the decider opens the shared file with its own handle and calls ensure_schema on it
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY)")
        db.commit()
        try:
            with self.assertRaises(verify_ledger.LedgerAbsentError) as ctx:
                verify_ledger.ensure_schema(db)
            self.assertIn("has no verify_messages table", str(ctx.exception))
            self.assertEqual({r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")},
                             {"decisions"})
            self.assertEqual(tables(self.prod), {"decisions"})
        finally:
            db.close()

    def test_ensure_schema_still_upgrades_a_production_ledger_that_has_the_send_record(self) -> None:
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT)")
        db.commit()
        try:
            verify_ledger.ensure_schema(db)
            cols = {r[1] for r in db.execute("PRAGMA table_info(verify_messages)")}
            self.assertIn("sent_at", cols)
            self.assertIn("verify_requests",
                          {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")})
        finally:
            db.close()

    def test_ensure_schema_still_creates_a_scratch_ledger(self) -> None:
        scratch = self.tmp / "elsewhere" / "ledger.sqlite3"
        verify_ledger.connect(str(scratch)).close()
        db = sqlite3.connect(scratch)
        try:
            db.execute("DROP TABLE verify_messages")
            db.commit()
            verify_ledger.ensure_schema(db)
            self.assertIn("verify_messages",
                          {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")})
        finally:
            db.close()

    def test_init_creates_it_once(self) -> None:
        self.prod.parent.mkdir()
        self.assertEqual(verify_ledger.init(str(self.prod))["result"], "created")
        verify_ledger.connect(str(self.prod)).close()         # now an ordinary open works
        self.assertIn("verify_messages", tables(self.prod))
        verify_ledger.connect_ro(str(self.prod), must_exist=True).close()

    def test_init_leaves_a_ledger_that_has_a_send_record_untouched(self) -> None:
        self.prod.parent.mkdir()
        verify_ledger.init(str(self.prod))
        db = sqlite3.connect(self.prod)
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) VALUES "
                   "('uvn-status','initial','a@x','2026-11-13','sent','email','[]',1,'t','t','t','t')")
        db.commit()
        db.close()
        before = self.prod.read_bytes()
        self.assertEqual(verify_ledger.init(str(self.prod))["result"], "exists")
        self.assertEqual(self.prod.read_bytes(), before)

    def test_init_refuses_a_file_that_holds_tables_but_no_send_record(self) -> None:
        # the decider shares the file: an older revision of it (or a restored backup) has decisions and no
        # verify_messages. Creating an empty send record beside that history says nobody was ever messaged.
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, outcome TEXT)")
        db.execute("INSERT INTO decisions (outcome) VALUES ('approved')")
        db.commit()
        db.close()
        before = self.prod.read_bytes()
        with self.assertRaises(verify_ledger.LedgerAbsentError) as ctx:
            verify_ledger.init(str(self.prod))
        self.assertIn("exists without a send record", str(ctx.exception))
        self.assertEqual(self.prod.read_bytes(), before)
        self.assertFalse(Path(str(self.prod) + "-wal").exists())
        self.assertFalse(Path(str(self.prod) + "-shm").exists())
        self.assertEqual(tables(self.prod), {"decisions"})
        db = sqlite3.connect(self.prod)
        try:
            self.assertEqual(db.execute("SELECT outcome FROM decisions").fetchall(), [("approved",)])
        finally:
            db.close()

    def test_init_refuses_a_restored_backup_taken_before_the_send_record_existed(self) -> None:
        self.prod.parent.mkdir()
        verify_ledger.init(str(self.prod))
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, outcome TEXT)")
        db.execute("INSERT INTO decisions (outcome) VALUES ('approved')")
        db.execute("INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, "
                   "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at) VALUES "
                   "('uvn-status','initial','a@x','2026-11-13','sent','email','[]',1,'t','t','t','t')")
        db.commit()
        db.close()
        backup = self.prod.read_bytes()
        self.prod.unlink()
        db = sqlite3.connect(self.prod)                       # the copy from before the send record existed
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, outcome TEXT)")
        db.execute("INSERT INTO decisions (outcome) VALUES ('approved')")
        db.commit()
        db.close()
        before = self.prod.read_bytes()
        with self.assertRaises(verify_ledger.LedgerAbsentError):
            verify_ledger.init(str(self.prod))
        with self.assertRaises(verify_ledger.LedgerAbsentError):
            verify_ledger.connect(str(self.prod))
        self.assertEqual(self.prod.read_bytes(), before)
        self.assertEqual(tables(self.prod), {"decisions"})
        self.prod.write_bytes(backup)                         # the real record is the only way back
        verify_ledger.connect(str(self.prod)).close()
        self.assertIn("verify_messages", tables(self.prod))

class PinnedPathTests(unittest.TestCase):
    """The rule is keyed to one path. It protects a sender only while that sender resolves to the same path."""

    def test_the_tick_resolves_its_ledger_to_the_production_path(self) -> None:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CVO_", "BATS_", "HYDRA_"))}
        out = subprocess.run(["bash", str(ROOT / "scripts" / "credit-verify-outbound.sh"), "--print-config"],
                             env=env, capture_output=True, text=True, check=True)
        cfg = dict(line.split("=", 1) for line in out.stdout.splitlines() if "=" in line)
        self.assertEqual(cfg["CVO_HARNESS"], "0")
        self.assertEqual(cfg["LEDGER"], verify_ledger.PRODUCTION_PATH)

    def test_a_ledger_env_var_does_not_move_it(self) -> None:
        env = dict(os.environ, CREDIT_REVIEW_LEDGER="/tmp/elsewhere.sqlite3", PYTHONPATH=str(ROOT / "scripts"))
        out = subprocess.run([sys.executable, "-c", "from credit_review import verify_ledger as v; "
                              "print(v.PRODUCTION_PATH)"], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "/var/lib/hydra/credit-review/ledger.sqlite3")

class RealEntrypointTests(Scratch):
    """`python3 -I verify_ledger.py`, the way the gate and deploy.sh run it."""

    def setUp(self) -> None:
        super().setUp()
        self.mirror = self.tmp / "credit_review"
        shutil.copytree(PKG, self.mirror, ignore=shutil.ignore_patterns("__pycache__"))
        src = (PKG / "verify_ledger.py").read_text()
        (self.mirror / "verify_ledger.py").write_text(src.replace(LITERAL, f"PRODUCTION_PATH = {str(self.prod)!r}"))

    def run_helper(self, *args: str, helper: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-I", str(helper or self.mirror / "verify_ledger.py"),
                               "--db", str(self.prod), *args], capture_output=True, text=True, check=False)

    def test_the_mirror_differs_from_the_checked_in_file_by_that_one_line(self) -> None:
        a = (PKG / "verify_ledger.py").read_text().splitlines()
        b = (self.mirror / "verify_ledger.py").read_text().splitlines()
        self.assertEqual(len(a), len(b))
        self.assertEqual([x for x, y in zip(a, b) if x != y], [LITERAL])

    def test_a_live_read_a_claim_and_migrate_all_refuse_a_missing_ledger(self) -> None:
        claim = ["claim", "--campaign", "uvn-status", "--user-key", "a@example.com", "--user-id", "4242",
                 "--day", "2026-11-13", "--request-ids", "11111111-1111-4111-8111-111111111111",
                 "--message-type", "email", "--approved-by", "t", "--approval-ref", "t", "--contact-id", "c1"]
        for args in (PENDING, claim, ["migrate"]):
            with self.subTest(op=args[0]):
                out = self.run_helper(*args)
                self.assertEqual(out.returncode, 2, out.stderr)
                self.assertEqual(out.stdout, "")              # no answer a caller could read as "never messaged"
                self.assertIn("refusing to create an empty send record", json.loads(out.stderr)["error"])
                self.assertFalse(self.prod.exists())
                self.assertFalse(self.prod.parent.exists())

    def test_init_is_the_way_in_and_the_read_then_answers(self) -> None:
        self.prod.parent.mkdir()
        self.assertEqual(self.run_helper("--readonly", "init").returncode, 2)
        self.assertFalse(self.prod.exists())
        out = self.run_helper("init")
        self.assertEqual((out.returncode, json.loads(out.stdout)["result"]), (0, "created"))
        self.assertIn("init: created the send record", out.stderr)      # who ran it is the journal's record
        self.assertEqual(json.loads(self.run_helper("init").stdout)["result"], "exists")
        peek = self.run_helper(*PENDING)
        self.assertEqual(peek.returncode, 0, peek.stderr)
        self.assertEqual(json.loads(peek.stdout)["user_done"], "")
        self.assertEqual(self.run_helper("migrate").returncode, 0)

    def test_init_refuses_a_file_with_decider_rows_and_no_send_record(self) -> None:
        self.prod.parent.mkdir()
        db = sqlite3.connect(self.prod)
        db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, outcome TEXT)")
        db.execute("INSERT INTO decisions (outcome) VALUES ('approved')")
        db.commit()
        db.close()
        before = self.prod.read_bytes()
        out = self.run_helper("init")
        self.assertEqual(out.returncode, 2, out.stdout)
        self.assertEqual(out.stdout, "")
        self.assertIn("exists without a send record", json.loads(out.stderr)["error"])
        self.assertEqual(self.prod.read_bytes(), before)
        self.assertFalse(Path(str(self.prod) + "-wal").exists())
        self.assertFalse(Path(str(self.prod) + "-shm").exists())
        self.assertEqual(tables(self.prod), {"decisions"})

    def test_the_checked_in_helper_still_creates_a_scratch_ledger(self) -> None:
        # for the unmodified file this temp path is not the production path: the blast radius is that one path
        self.prod.parent.mkdir()
        out = self.run_helper(*PENDING, helper=PKG / "verify_ledger.py")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("verify_messages", tables(self.prod))


# --- Suite two: the capped run's read-back asks capped() itself (lane verif-sender-cluster-scale-k1) ---

READBACK = ROOT / "data" / "verif-sender-cluster-scale-k1" / "readback.py"
INS = ("INSERT INTO verify_messages (campaign, kind, user_key, account_id, day, status, message_type, "
       "request_ids_json, n_credits, approved_by, approval_ref, created_at, updated_at, sent_at) "
       "VALUES ('proof-need-ask', 'initial', ?, ?, ?, ?, 'email', ?, 1, 't', 't', ?, ?, ?)")

def load() -> object:
    spec = importlib.util.spec_from_file_location("verif_sender_readback", READBACK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

class ReadbackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="verif-readback-"))
        self.path = self.tmp / "ledger.sqlite3"
        self.db = verify_ledger.connect(str(self.path))
        self.db.execute("CREATE TABLE decisions (id INTEGER PRIMARY KEY, request_id TEXT, user_id TEXT, outcome TEXT)")
        self.addCleanup(self.db.close)
        self.readback = load()

    def row(self, user_key: str, account_id: str | None, day: str = "2026-11-13", status: str = "sent",
            requests: str = "[]", sent_at: str | None = "2026-11-13T12:00:00Z",
            created_at: str = "2026-11-13T12:00:00Z") -> int:
        cur = self.db.execute(INS, (user_key, account_id, day, status, requests, created_at, created_at, sent_at))
        return int(cur.lastrowid)

    def test_a_pair_capped_refuses_is_reported_even_with_no_shared_token(self) -> None:
        a = self.row("a@x", "9")
        b = self.row("b@x", None, requests='["r7"]', sent_at="2026-11-13T12:20:00Z")
        self.db.execute("INSERT INTO decisions (request_id, user_id, outcome) VALUES ('r7', 7, 'approved')")
        self.db.commit()
        # the premise: the decider asks about this person by email and user id, and capped() refuses them
        self.assertTrue(verify_ledger.capped(self.db, user_key="a@x", day="2026-11-13", user_id="7"))
        # and no identity column groups them together: pairwise tokens give {a@x, 9} and {b@x, 7}
        self.assertEqual(self.db.execute("SELECT user_key, account_id FROM verify_messages WHERE id = ?",
                                         (b,)).fetchone()["user_key"], "b@x")

        out = self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")
        listed = [d for d in out["duplicates"] if d["rows"] == [a, b]]
        self.assertTrue(listed, out["duplicates"])
        self.assertEqual([d["cross_identity"] for d in listed], [True])       # no single row supplies both
        self.assertEqual(out["duplicate_counts"], [{"day": "2026-11-13", "real": 0, "cross_identity": len(listed)}])
        self.assertEqual(out["hourly_asks"], [{"utc_hour": "2026-11-13T12", "campaign": "proof-need-ask", "sent": 2}])

    def test_a_day_with_one_note_reports_nothing(self) -> None:
        self.row("a@x", "9")
        self.db.commit()
        self.assertEqual(self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")["duplicates"], [])

    def test_two_different_people_in_one_tick_report_no_real_duplicate(self) -> None:
        # the case report.md's clean-tick criterion 1 is measured with: two people, one note each, same tick
        self.row("a@x", "9")
        self.row("d@y", "4", sent_at="2026-11-13T12:00:30Z")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")
        self.assertTrue(out["duplicates"])  # the cross-pairs are still reported, never hidden
        self.assertEqual([d for d in out["duplicates"] if d["cross_identity"] is False], [])
        self.assertEqual(out["duplicate_counts"], [{"day": "2026-11-13", "real": 0,
                                                    "cross_identity": len(out["duplicates"])}])

    def test_a_second_note_to_one_person_is_a_real_duplicate(self) -> None:
        a = self.row("a@x", "9")
        b = self.row("a@x", "9", sent_at="2026-11-13T12:30:00Z")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")
        real = [d for d in out["duplicates"] if d["cross_identity"] is False]
        self.assertTrue(real, out["duplicates"])
        self.assertIn(sorted([a, b]), [sorted(d["rows"]) for d in real])

    def test_every_entry_names_the_rows_it_matched(self) -> None:
        a = self.row("a@x", "9")
        b = self.row("b@x", "8")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")
        self.assertTrue(out["duplicates"])
        for entry in out["duplicates"]:
            self.assertGreater(len(entry["rows"]), 1)
            self.assertTrue(set(entry["rows"]) <= {a, b})
            self.assertEqual(set(entry), {"day", "rows", "cross_identity"})

    def test_a_refused_or_deferred_note_does_not_count(self) -> None:
        self.row("a@x", "9", status="sent")
        self.row("a@x", "9", status="refused")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")
        self.assertEqual(out["duplicates"], [])

    def test_the_window_starts_at_since(self) -> None:
        self.row("a@x", "9", day="2026-11-12", sent_at="2026-11-12T10:00:00Z")
        self.row("a@x", "9", day="2026-11-12", sent_at="2026-11-12T11:00:00Z")
        self.row("a@x", "9", day="2026-11-13", sent_at="2026-11-13T10:00:00Z")
        self.db.commit()
        self.assertEqual(self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")["duplicates"], [])
        self.assertEqual(self.readback.readback(str(self.path), "2026-11-13T00:00:00Z")["hourly_asks"],
                         [{"utc_hour": "2026-11-13T10", "campaign": "proof-need-ask", "sent": 1}])
        self.assertEqual({d["day"] for d in self.readback.readback(str(self.path), "2026-11-12T00:00:00Z")["duplicates"]},
                         {"2026-11-12"})

    def test_a_pair_from_before_a_non_midnight_window_is_cap_history_not_a_violation(self) -> None:
        first = self.row("a@x", "9", sent_at="2026-11-13T10:00:00Z")
        second = self.row("a@x", "9", sent_at="2026-11-13T11:00:00Z")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T22:00:00Z")
        self.assertEqual(out["duplicates"], [])
        self.assertEqual(out["duplicate_counts"], [{"day": "2026-11-13", "real": 0, "cross_identity": 0}])
        self.assertEqual(out["hourly_asks"], [])

        # the capped run writes a third note for that person at 23:00: now it is a violation of THIS window, and the
        # two earlier notes stay in the rows it names as cap history
        third = self.row("a@x", "9", sent_at="2026-11-13T23:00:00Z")
        self.db.commit()
        out = self.readback.readback(str(self.path), "2026-11-13T22:00:00Z")
        self.assertEqual([d for d in out["duplicates"] if d["cross_identity"] is False],
                         [{"day": "2026-11-13", "rows": [first, second, third], "cross_identity": False}])
        self.assertEqual(out["hourly_asks"],
                         [{"utc_hour": "2026-11-13T23", "campaign": "proof-need-ask", "sent": 1}])

    def test_an_attempted_row_is_in_the_window_by_when_it_was_created(self) -> None:
        sent = self.row("a@x", "9", sent_at="2026-11-13T10:00:00Z")
        early = self.row("a@x", "9", status="attempted", sent_at=None, created_at="2026-11-13T11:00:00Z")
        self.db.commit()
        self.assertEqual(self.readback.readback(str(self.path), "2026-11-13T22:00:00Z")["duplicates"], [])

        late = self.row("a@x", "9", status="attempted", sent_at=None, created_at="2026-11-13T23:30:00Z")
        self.db.commit()
        real = [d for d in self.readback.readback(str(self.path), "2026-11-13T22:00:00Z")["duplicates"]
                if d["cross_identity"] is False]
        self.assertEqual(real, [{"day": "2026-11-13", "rows": [sent, early, late], "cross_identity": False}])

    def test_it_never_prints_a_person(self) -> None:
        email_a, email_b = "leaky-a@example.com", "leaky-b@example.com"
        uid_a, uid_b = "987654321", "123456789"
        first = self.row(email_a, uid_a)
        second = self.row(email_a, uid_a, sent_at="2026-11-13T12:30:00Z")      # one person, two notes
        third = self.row(email_b, None, requests='["r7"]', sent_at="2026-11-13T12:40:00Z")
        self.db.execute("INSERT INTO decisions (request_id, user_id, outcome) VALUES ('r7', ?, 'approved')", (uid_b,))
        self.db.commit()
        out = subprocess.run([sys.executable, str(READBACK), "--db", str(self.path),
                              "--since", "2026-11-13T00:00:00Z"], capture_output=True, text=True, check=True)
        printed = json.loads(out.stdout)
        self.assertEqual([d for d in printed["duplicates"] if d["cross_identity"] is False],
                         [{"day": "2026-11-13", "rows": [first, second], "cross_identity": False}])
        self.assertIn(third, [row for d in printed["duplicates"] if d["cross_identity"] for row in d["rows"]])
        for secret in (email_a, email_b, uid_a, uid_b):
            self.assertNotIn(secret, out.stdout)
        self.assertEqual(printed["duplicate_counts"],
                         [{"day": "2026-11-13", "real": 1,
                           "cross_identity": len([d for d in printed["duplicates"] if d["cross_identity"]])}])

    def test_it_never_creates_the_ledger_it_reads(self) -> None:
        missing = self.tmp / "absent.sqlite3"
        with self.assertRaises(verify_ledger.ReadOnlyLedgerError):
            self.readback.readback(str(missing), "2026-11-13T00:00:00Z")
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
