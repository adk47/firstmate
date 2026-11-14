#!/usr/bin/env python3
"""precedent_v1's approvals reach the request ledger (credit_review/reconcile_approved.py).

The incident: prev2.js approves in core's Postgres from inside a pod, and the undecided count is
read from `request_state`, a SQLite table on node-8 the pod cannot reach. On 2026-11-14 the newest
row of `request_state_log` was 80 hours old and no row in either table had ever said APPROVED.

Every ledger here is built from the LIVE schema (fixtures/credit-precedent/
request-ledger-live-schema.sql), which is not the DDL in request_state.py: it has two more columns
and a trigger, rs_audit, that no tracked file creates. Nothing here reaches node-8 or the replica:
the replica is a function the test supplies.

What must hold:
  * a result line moves its ids to APPROVED, and the same line a second time moves none;
  * one move is ONE request_state_log row; the second log, state_transitions, is the trigger's;
  * a line that cannot be read, or a ledger that is not the ledger, moves nothing;
  * the backfill moves only what core says is approved, and moves nothing when core half answers;
  * a count that could not be read is never printed as 0.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import reconcile_approved as ra  # noqa: E402
from credit_review import request_state  # noqa: E402

MODULE = ROOT / "scripts" / "credit_review" / "reconcile_approved.py"
SCHEMA = ROOT / "scripts" / "tests" / "fixtures" / "credit-precedent" / "request-ledger-live-schema.sql"

A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"
C = "33333333-3333-4333-8333-333333333333"
D = "44444444-4444-4444-8444-444444444444"
E = "55555555-5555-4555-8555-555555555555"
RUN = "prev-2026-11-14T12"


def line(ids, run=RUN, **over):
    return json.dumps({"marker": "PREV2_RESULT", "run": run, "changed": len(ids),
                       "approved": len(ids), "approved_ids": list(ids), **over})


class LedgerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / "ledger.sqlite3")
        db = sqlite3.connect(self.path)
        db.executescript(SCHEMA.read_text())
        db.commit()
        db.close()

    def seed(self, *rows):
        """(request id, state) rows, written the way the 2026-11-11 backfill wrote them."""
        db = sqlite3.connect(self.path)
        for rid, state in rows:
            db.execute("INSERT INTO request_state(request_id,state,entered_at,reason,actor) "
                       "VALUES(?,?,?,?,?)", (rid, state, "2026-11-11T00:57:50Z", "seed", "backfill"))
        db.commit()
        db.close()

    def q(self, sql, *args):
        db = sqlite3.connect(self.path)
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def states(self):
        return dict(self.q("SELECT request_id, state FROM request_state"))

    def reconcile(self, ids, run=RUN):
        db = ra.open_ledger(self.path)
        try:
            return ra.reconcile(db, list(ids), run)
        finally:
            db.close()


class RecurringStep(LedgerCase):
    def test_a_result_line_moves_its_ids_to_approved(self):
        self.seed((A, "ASKED"), (B, "OPEN_UNASKED"))
        out = self.reconcile([A, B, C])
        self.assertEqual(out, {"moved": 3, "offered": 3, "already": 0, "run": RUN,
                               "moved_from": {"ASKED": 1, "OPEN_UNASKED": 1, "no_row": 1}})
        self.assertEqual(self.states(), {A: "APPROVED", B: "APPROVED", C: "APPROVED"})

    def test_the_same_line_a_second_time_moves_none_and_writes_no_row(self):
        self.seed((A, "ASKED"), (B, "OPEN_UNASKED"))
        self.reconcile([A, B, C])
        before = self.q("SELECT count(*) FROM request_state_log"), self.q("SELECT * FROM request_state")
        out = self.reconcile([A, B, C])
        self.assertEqual((out["moved"], out["already"], out["moved_from"]), (0, 3, {}))
        after = self.q("SELECT count(*) FROM request_state_log"), self.q("SELECT * FROM request_state")
        self.assertEqual(before, after)

    def test_one_move_is_one_log_row_and_the_second_log_is_the_triggers(self):
        # A has a row, C has none. rs_audit fires AFTER UPDATE OF state, so only A reaches it.
        self.seed((A, "ASKED"))
        self.reconcile([A, C])
        ours = self.q("SELECT request_id, from_state, to_state, reason, actor FROM request_state_log "
                      "ORDER BY request_id")
        self.assertEqual(ours, [(A, "ASKED", "APPROVED", f"precedent_v1 run {RUN}", "prev2"),
                                (C, None, "APPROVED", f"precedent_v1 run {RUN}", "prev2")])
        theirs = self.q("SELECT request_id, from_state, to_state, actor, reason FROM state_transitions")
        self.assertEqual(theirs, [(A, "ASKED", "APPROVED", "trigger", None)])

    def test_this_module_writes_no_statement_against_the_triggers_table(self):
        for name in (MODULE, MODULE.with_name("request_state.py")):
            self.assertNotIn("state_transitions", name.read_text(), name.name)

    def test_a_failure_part_way_moves_nothing(self):
        self.seed((A, "ASKED"), (B, "OPEN_UNASKED"))
        real = request_state.transition

        def second_fails(db, rid, *a, **k):
            if rid == B:
                raise sqlite3.OperationalError("disk I/O error")
            return real(db, rid, *a, **k)

        with mock.patch.object(request_state, "transition", second_fails):
            with self.assertRaises(sqlite3.OperationalError):
                self.reconcile([A, B])
        self.assertEqual(self.states(), {A: "ASKED", B: "OPEN_UNASKED"})
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(0,)])
        self.assertEqual(self.q("SELECT count(*) FROM state_transitions"), [(0,)])

    def test_a_run_that_approved_nothing_is_a_line_and_moves_nothing(self):
        got = ra.parse_result(line([]))
        self.assertEqual(got, {"run": RUN, "ids": []})
        self.assertEqual(self.reconcile([])["offered"], 0)

    def test_approved_is_the_declared_name_and_request_state_is_the_node8_file_plus_one_block(self):
        self.assertEqual(ra.TERMINAL, "APPROVED")
        self.assertIn("APPROVED          approved (by proof, precedent, or validator)", request_state.__doc__)
        # request_state.py is /opt/hydra/scripts/credit_review/request_state.py as node-8 held it on
        # 2026-11-11 (the file every row in the ledger was written through) plus ONE marked block in
        # backfill(). Take the block out and the bytes are node-8's. A change outside the block is
        # a change to that contract: make it on purpose and move this digest with it.
        lines = MODULE.with_name("request_state.py").read_text().splitlines(keepends=True)
        begin = [i for i, text in enumerate(lines) if text.strip() == "# >>> not in node-8's copy"]
        end = [i for i, text in enumerate(lines) if text.strip() == "# <<< not in node-8's copy"]
        self.assertEqual((len(begin), len(end)), (1, 1))
        self.assertLess(begin[0], end[0])
        node8 = "".join(lines[:begin[0]] + lines[end[0] + 1:]).encode()
        self.assertEqual(hashlib.sha256(node8).hexdigest(),
                         "429639b66f5a128c32412d56797d81dc57ce898c5e4f7d733e8043b084c4e8c0")


class OlderBackfill(LedgerCase):
    """request_state.backfill(), the 2026-11-11 one that derives ASKED and the rest from the asks
    sent. Until APPROVED was written it had nothing to take back."""

    def setUp(self):
        super().setUp()
        db = sqlite3.connect(self.path)
        # Only the columns backfill() reads; this is not verify_messages' live schema.
        db.execute("CREATE TABLE verify_messages(request_ids_json TEXT, kind TEXT, status TEXT, "
                   "sent_at TEXT, last_reply_at TEXT, proof_attachments INTEGER, user_key TEXT)")
        db.execute("INSERT INTO verify_messages VALUES(?,?,?,?,?,?,?)",
                   (json.dumps([A, B]), "ask", "sent", "2026-11-01T00:00:00Z", None, 0, "user-1"))
        db.execute("INSERT INTO verify_messages VALUES(?,?,?,?,?,?,?)",
                   (json.dumps([C]), "ask", "sent", "2026-11-02T00:00:00Z", None, 2, "user-2"))
        db.commit()
        db.close()

    def older_backfill(self):
        db = sqlite3.connect(self.path)
        try:
            return request_state.backfill(db)
        finally:
            db.close()

    def test_it_does_not_take_an_approved_request_back_to_asked(self):
        self.assertEqual(self.older_backfill(), 3)
        self.assertEqual(self.states(), {A: "ASKED", B: "ASKED", C: "PROOF_RECEIVED"})
        self.reconcile([A, C, D])  # D was never asked: no row until now, so no user_key
        rows = self.q("SELECT count(*) FROM request_state_log")

        self.assertEqual(self.older_backfill(), 0)

        self.assertEqual(self.states(), {A: "APPROVED", B: "ASKED", C: "APPROVED", D: "APPROVED"})
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), rows)
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log WHERE from_state='APPROVED'"),
                         [(0,)])

    def test_a_request_it_has_not_seen_approved_is_still_derived_from_its_ask(self):
        self.reconcile([A])
        self.assertEqual(self.older_backfill(), 2)
        self.assertEqual(self.states(), {A: "APPROVED", B: "ASKED", C: "PROOF_RECEIVED"})
        # It still fills the user key of a row the reconcile step inserted without one.
        self.assertEqual(self.q("SELECT user_key FROM request_state WHERE request_id=?", A),
                         [("user-1",)])


class ResultLine(unittest.TestCase):
    def refused(self, text, why):
        with self.assertRaises(ra.NoResult) as ctx:
            ra.parse_result(text)
        self.assertIn(why, str(ctx.exception))

    def test_it_is_found_in_the_approvers_whole_output_and_the_last_one_wins(self):
        text = "\n".join(["candidates: 3 eligible(>=3 precedent): 3", "safe to approve: 3",
                          f"APPROVED: 1 run: {RUN} ids: {A} skipped at write: {{}}",
                          line([A]), line([A, B])])
        self.assertEqual(ra.parse_result(text), {"run": RUN, "ids": [A, B]})

    def test_output_with_no_line_is_refused(self):
        self.refused("candidates: 3\nsafe to approve: 0\nDRY RUN — nothing written\n", "no PREV2_RESULT line")
        self.refused(f"post-state: unknown (post_state_read_failed: x) run: {RUN}", "no PREV2_RESULT line")
        self.refused("", "no PREV2_RESULT line")

    def test_a_cut_line_is_refused(self):
        self.refused(line([A, B])[:-20], "not JSON")

    def test_a_count_that_disagrees_with_the_list_is_refused(self):
        self.refused(line([A, B], approved=3), "approved says 3 and approved_ids holds 2")
        self.refused(line([A], approved=True), "approved says True")

    def test_an_id_that_is_not_a_request_id_is_refused(self):
        self.refused(line([A, "claim-12"]), "1 of 2 approved_ids are not request ids")
        self.refused(line([A, None]), "not request ids")

    def test_a_repeated_id_and_a_missing_run_are_refused(self):
        self.refused(line([A, A]), "repeats an id")
        self.refused(line([A], run=""), "names no run")
        self.refused(json.dumps({"marker": "PREV2_RESULT", "run": RUN, "approved": 0}), "not a list")


class RealEntrypoint(LedgerCase):
    """The unit runs this as a FILE with the approver's stdout on stdin; so do these."""

    def run_file(self, *args, stdin=""):
        return subprocess.run([sys.executable, str(MODULE), *args], input=stdin, capture_output=True,
                              text=True, timeout=60, check=False)

    def test_stdin_is_echoed_and_the_summary_is_the_last_line(self):
        self.seed((A, "ASKED"))
        text = f"candidates: 2 eligible(>=3 precedent): 2\nsafe to approve: 2\n{line([A, C])}\n"
        p = self.run_file("--ledger", self.path, "--echo", stdin=text)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout.splitlines()
        self.assertEqual(out[:3], text.splitlines())
        self.assertEqual(json.loads(out[3]), {"moved": 2, "offered": 2, "already": 0, "run": RUN,
                                              "moved_from": {"ASKED": 1, "no_row": 1}})
        again = self.run_file("--ledger", self.path, stdin=text)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(json.loads(again.stdout)["moved"], 0)

    def test_no_result_line_is_exit_2_and_nothing_moves(self):
        self.seed((A, "ASKED"))
        p = self.run_file("--ledger", self.path, stdin="safe to approve: 0\nERR connection refused\n")
        self.assertEqual(p.returncode, ra.EXIT_NO_RESULT)
        self.assertIn("nothing was moved", p.stderr)
        self.assertEqual(self.states(), {A: "ASKED"})

    def test_a_path_with_no_ledger_is_exit_3_and_no_file_is_made(self):
        missing = str(Path(self.tmp.name) / "nope.sqlite3")
        p = self.run_file("--ledger", missing, stdin=line([A]))
        self.assertEqual(p.returncode, ra.EXIT_LEDGER)
        self.assertIn("does not exist", p.stderr)
        self.assertFalse(Path(missing).exists())

    def test_a_database_that_is_not_the_request_ledger_is_exit_3(self):
        other = str(Path(self.tmp.name) / "other.sqlite3")
        sqlite3.connect(other).executescript("CREATE TABLE verify_messages(id INTEGER);")
        p = self.run_file("--ledger", other, stdin=line([A]))
        self.assertEqual(p.returncode, ra.EXIT_LEDGER)
        self.assertIn("has no request_state or request_state_log table", p.stderr)
        self.assertEqual(sqlite3.connect(other).execute(
            "SELECT count(*) FROM sqlite_master WHERE name LIKE 'request_state%'").fetchone(), (0,))


class Core:
    """A stand-in for the replica: what core holds, and every statement it was asked."""

    def __init__(self, rows, fail_from=None):
        self.rows, self.asked, self.fail_from = rows, [], fail_from

    def __call__(self, sql):
        self.asked.append(sql)
        if self.fail_from is not None and len(self.asked) >= self.fail_from:
            raise RuntimeError("trino failed: Query exceeded maximum time limit")
        if sql == ra.CORE_UNDECIDED_SQL:  # the one read of everything core has not decided
            return [[rid, r[0], r[1], ""] for rid, r in self.rows.items() if r[0] not in ra.CORE_DECIDED]
        return [[rid, *self.rows[rid]] for rid in self.rows if f"UUID '{rid}'" in sql]


class Backfill(LedgerCase):
    def setUp(self):
        super().setUp()
        self.seed((A, "ASKED"), (B, "OPEN_UNASKED"), (C, "PROOF_RECEIVED"), (D, "ASKED"), (E, "ASKED"),
                  ("claim-17", "ASKED"), ("66666666-6666-4666-8666-666666666666", "CLOSED_STALE"))
        self.core = Core({A: ["approved", "false", "precedent_v1"], B: ["approved", "false", ""],
                          C: ["rejected", "false", ""], D: ["user_verification_needed", "true", ""],
                          E: ["user_verification_needed", "false", ""]})

    def test_the_plan_sorts_every_undecided_request_and_writes_nothing(self):
        before = Path(self.path).read_bytes()
        out = ra.backfill(self.path, apply=False, query=self.core)
        self.assertEqual(out, {
            "mode": "plan", "ledger_undecided": 6, "not_a_credit_request_id": 1, "asked": 5,
            "asked_by_id": 3,
            "core": {"approved": 2, "deleted_while_undecided": 1, "rejected": 1, "undecided_in_core": 1},
            "approved_via": {"not recorded": 1, "precedent_v1": 1}, "to_move": 2})
        self.assertEqual(sum(out["core"].values()), out["asked"])
        self.assertEqual(Path(self.path).read_bytes(), before)
        self.assertNotIn("claim-17", " ".join(self.core.asked))

    def test_only_what_core_no_longer_holds_as_undecided_is_asked_about_by_id(self):
        ra.backfill(self.path, apply=False, query=self.core)
        self.assertEqual(self.core.asked[0], ra.CORE_UNDECIDED_SQL)
        self.assertEqual(len(self.core.asked), 2)
        for rid, asked in ((A, True), (B, True), (C, True), (D, False), (E, False)):
            self.assertEqual(rid in self.core.asked[1], asked, rid)

    def test_a_request_neither_read_names_is_not_in_core_and_is_not_moved(self):
        del self.core.rows[A]
        out = ra.backfill(self.path, apply=True, query=self.core)
        self.assertEqual(out["core"]["not_in_core"], 1)
        self.assertEqual((out["moved"], self.states()[A]), (1, "ASKED"))

    def test_an_undecided_read_that_answers_nothing_or_nonsense_moves_nothing(self):
        answers = ([], [[A, "approved", "false", ""]], [[A, "unverified", "?", ""]], [["claim-1", "unverified", "false", ""]],
                   [[E, "unverified", "false", ""], [E, "unverified", "false", ""]])
        for rows in answers:
            with self.subTest(rows=rows), self.assertRaises(ra.CoreUnread):
                ra.backfill(self.path, apply=True, query=lambda sql, r=rows: r)
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(0,)])

    def test_apply_moves_only_what_core_approved(self):
        out = ra.backfill(self.path, apply=True, query=self.core)
        self.assertEqual((out["mode"], out["moved"], out["offered"]), ("applied", 2, 2))
        self.assertEqual(out["moved_from"], {"ASKED": 1, "OPEN_UNASKED": 1})
        states = self.states()
        self.assertEqual((states[A], states[B]), ("APPROVED", "APPROVED"))
        self.assertEqual((states[C], states[D], states[E], states["claim-17"]),
                         ("PROOF_RECEIVED", "ASKED", "ASKED", "ASKED"))
        self.assertEqual(
            self.q("SELECT request_id, reason, actor FROM request_state_log ORDER BY request_id"),
            [(A, "backfill: approved in core (via precedent_v1)", "reconcile-backfill"),
             (B, "backfill: approved in core (via not recorded)", "reconcile-backfill")])

    def test_a_request_core_approved_and_then_deleted_is_counted_and_not_moved(self):
        # `measure` reads core with `deletedat IS NULL`, so a deleted row is in neither of core's
        # counts. Moving it would lower the ledger's count for an approval core no longer holds.
        core = Core({**self.core.rows, A: ["approved", "true", "precedent_v1"]})
        plan = ra.backfill(self.path, apply=False, query=core)
        self.assertEqual(plan["core"], {"approved": 1, "approved_and_deleted": 1,
                                        "deleted_while_undecided": 1, "rejected": 1,
                                        "undecided_in_core": 1})
        self.assertEqual((plan["to_move"], plan["approved_via"]), (1, {"not recorded": 1}))
        self.assertEqual(sum(plan["core"].values()), plan["asked"])

        out = ra.backfill(self.path, apply=True, query=core)

        self.assertEqual(out["moved"], 1)
        self.assertEqual(self.states()[A], "ASKED")
        self.assertEqual(self.states()[B], "APPROVED")
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log WHERE request_id=?", A), [(0,)])

    def test_a_second_apply_moves_none_and_does_not_ask_about_what_it_moved(self):
        ra.backfill(self.path, apply=True, query=self.core)
        again = Core(self.core.rows)
        out = ra.backfill(self.path, apply=True, query=again)
        self.assertEqual((out["to_move"], out["moved"], out["asked"], out["asked_by_id"]), (0, 0, 3, 1))
        self.assertNotIn(A, " ".join(again.asked))
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(2,)])

    def test_a_chunk_that_does_not_answer_moves_nothing_even_after_one_that_did(self):
        failing = Core(self.core.rows, fail_from=3)  # the undecided read, one chunk, then silence
        with mock.patch.object(ra, "CHUNK", 2), self.assertRaises(ra.CoreUnread) as ctx:
            ra.backfill(self.path, apply=True, query=failing)
        self.assertIn("chunk at 2 of 3", str(ctx.exception))
        self.assertEqual(len(failing.asked), 3)
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(0,)])
        self.assertEqual(self.states()[A], "ASKED")

    def test_an_answer_this_cannot_read_moves_nothing(self):
        for bad in (["approved", "maybe", ""], ["", "false", ""], ["approved", "false"]):
            with self.subTest(bad=bad), self.assertRaises(ra.CoreUnread):
                ra.backfill(self.path, apply=True, query=Core({**self.core.rows, A: bad}))
        stranger = Core(self.core.rows)
        stranger.rows = {**self.core.rows, "77777777-7777-4777-8777-777777777777": ["approved", "false", ""]}
        with self.assertRaises(ra.CoreUnread):  # a by-id answer about an id nobody asked about
            ra.backfill(self.path, apply=True,
                        query=lambda sql: stranger(sql) if sql == ra.CORE_UNDECIDED_SQL else
                        [["77777777-7777-4777-8777-777777777777", "approved", "false", ""]])
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(0,)])

    def test_a_by_id_statement_stays_under_the_size_trino_turns_into_a_range(self):
        # Measured on the replica 2026-11-14: 256 ids 3.6 s; 257 ids a full scan and a statement timeout.
        self.assertLessEqual(ra.CHUNK, 256)

    def test_only_a_request_id_becomes_statement_text(self):
        with self.assertRaises(ValueError):
            ra.status_sql([A, "x') OR 1=1 --"])
        self.assertIn(f"WHERE id IN (UUID '{A}', UUID '{B}')", ra.status_sql([A, B]))

    def test_the_cli_says_core_was_not_read_and_exits_4(self):
        # The real path: replica() -> verify_notify.trino. Only the client's one call is replaced.
        from credit_review import verify_notify

        def down(sql, cmd=None):
            raise RuntimeError("trino failed: connection refused")

        with mock.patch.object(verify_notify, "trino", down), mock.patch("sys.stderr") as err:
            rc = ra.main(["backfill", "--ledger", self.path, "--apply"])
        self.assertEqual(rc, ra.EXIT_CORE_UNREAD)
        said = "".join(c.args[0] for c in err.write.call_args_list)
        self.assertIn("core was not read (the undecided read: trino failed: connection refused)", said)
        self.assertIn("nothing was moved", said)
        self.assertEqual(self.q("SELECT count(*) FROM request_state_log"), [(0,)])


class Measure(LedgerCase):
    CORE = [["approved", "5379005"], ["rejected", "180602"], ["user_verification_needed", "79791"],
            ["unverified", "21624"], ["processing", "2"]]
    NOW = 1794659890.0  # 2026-11-14T12:38:10Z

    def setUp(self):
        super().setUp()
        self.seed((A, "ASKED"), (B, "OPEN_UNASKED"), (C, "PROOF_RECEIVED"), (D, "CLOSED_STALE"),
                  (E, "DUPLICATE"))
        db = sqlite3.connect(self.path)
        db.execute("INSERT INTO request_state_log(request_id,to_state,at,actor) VALUES(?,?,?,?)",
                   (D, "CLOSED_STALE", "2026-11-11T04:27:03Z", "decider-v1"))
        db.commit()
        db.close()

    def test_both_counts_side_by_side(self):
        m = ra.measure(self.path, query=lambda sql: self.CORE, now=self.NOW)
        self.assertEqual(m["core"]["undecided"], 79791 + 21624 + 2)
        self.assertEqual(m["ledger"]["undecided"], 3)
        self.assertEqual(m["ledger"]["last_transition_at"], "2026-11-11T04:27:03Z")
        self.assertEqual(m["ledger"]["last_transition_age_h"], 80.19)
        text = ra.render_measure(m)
        self.assertIn("  core    credit_requests.status   101,417", text)
        self.assertIn("  node-8  request_state            3", text)
        self.assertIn("2026-11-11T04:27:03Z (80.19 h ago)", text)

    def test_the_core_count_is_the_not_deleted_rows(self):
        asked = []
        ra.measure(self.path, query=lambda sql: asked.append(sql) or self.CORE, now=self.NOW)
        self.assertEqual(len(asked), 1)
        self.assertIn("WHERE deletedat IS NULL GROUP BY status", asked[0])

    def test_a_side_that_was_not_read_is_not_measured_never_zero(self):
        def down(sql):
            raise RuntimeError("trino failed: connection refused")

        m = ra.measure(self.path, query=down, now=self.NOW)
        self.assertIsNone(m["core"]["undecided"])
        self.assertEqual(m["ledger"]["undecided"], 3)
        self.assertIn("core    credit_requests.status   NOT MEASURED (trino failed: connection refused)",
                      ra.render_measure(m))

        m = ra.measure(str(Path(self.tmp.name) / "nope.sqlite3"), query=lambda sql: self.CORE, now=self.NOW)
        self.assertIsNone(m["ledger"]["undecided"])
        self.assertIn("node-8  request_state            NOT MEASURED", ra.render_measure(m))
        self.assertFalse((Path(self.tmp.name) / "nope.sqlite3").exists())

    def test_an_answer_that_is_not_the_status_table_is_not_measured(self):
        for rows in ([], [["user_verification_needed", "12"]], [["approved", "many"]],
                     [["approved", "1"], ["approved", "2"]], [["approved"]]):
            with self.subTest(rows=rows):
                self.assertIsNone(ra.measure(self.path, query=lambda sql, r=rows: r)["core"]["undecided"])

    def test_measuring_writes_nothing(self):
        before = Path(self.path).read_bytes()
        ra.measure(self.path, query=lambda sql: self.CORE, now=self.NOW)
        self.assertEqual(Path(self.path).read_bytes(), before)

    def test_the_exit_code_says_which_side_was_not_read(self):
        from credit_review import verify_notify

        def down(sql, cmd=None):
            raise RuntimeError("trino failed: connection refused")

        with mock.patch.object(verify_notify, "trino", down), mock.patch("sys.stdout"):
            self.assertEqual(ra.main(["measure", "--ledger", self.path]), ra.EXIT_CORE_UNREAD)
            missing = str(Path(self.tmp.name) / "nope.sqlite3")
            self.assertEqual(ra.main(["measure", "--ledger", missing]), ra.EXIT_LEDGER)
        with mock.patch.object(verify_notify, "trino", lambda sql, cmd=None: self.CORE), \
                mock.patch("sys.stdout"):
            self.assertEqual(ra.main(["measure", "--ledger", self.path, "--json"]), ra.EXIT_OK)


if __name__ == "__main__":
    unittest.main()
