"""Caroline's send ledger: the writer (credit_review.verify_ledger, called by
intercom-verify-request.sh) and credit-retro's reader (credit_retro.waves.already_engaged,
used by the take-back gate) agree on verify_messages (firstmate 041, Fable option a).

- `verify_ledger.py migrate` creates the verify tables in an EXISTING shared ledger (the
  decider's tables live in the same file) without touching anything else, idempotently.
- The reader's required columns are exactly what the writer's schema provides.
- What the writer records (a sent note, a proof tag) is what the reader sees."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
