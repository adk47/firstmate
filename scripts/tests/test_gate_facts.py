"""The send gate's per-person replica read (credit_review/replica_batch.py, gate_facts.py, replica-serve.sh).

What these pin, in order of what would hurt:

  * the read can only make a check FASTER: with it, without it, with a stale one or with garbage in its place, the
    helpers return the same answer - and a failed batch returns no partial answer at all;
  * a read never answers a different question: statements are matched by exact text, and a statement the read does
    not hold is run live, through the real wrapper, byte for byte;
  * the prediction is complete for the families the tick sends: every statement core_notice and comm_state ask
    about a person is in the plan (the helpers are NOT changed by this, so the plan's copy of their statement text
    is checked here against what the real functions ask), and the gate makes ONE replica round trip per person
    instead of five or six;
  * one round trip really is one invocation of the wrapper (counted through a stand-in for trino-query.sh).

The replica is a stand-in script; nothing here reaches node-8, Trino or Intercom.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log

import importlib.util
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import comm_state as cs  # noqa: E402
from credit_review import fraud_lens, gate_facts, replica_batch as rb, uvn_status  # noqa: E402
from credit_review import verify_ledger as vl  # noqa: E402

CR = ROOT / "scripts" / "credit_review"
_spec = importlib.util.spec_from_file_location("core_notice", CR / "core_notice.py")   # it runs as a file, not a module
core_notice = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core_notice)

UID = 42
OLD = (datetime.now(timezone.utc) - timedelta(days=30)).strftime("%Y-%m-%d %H:%M:%S.000 UTC")
REQ = "0a000000-0000-4000-8000-000000000001"

# A stand-in for trino-query.sh: SQL on stdin, CSV on stdout, one line appended to $STUB_CALLS per INVOCATION.
# Statements are split on the batch separator; a `SELECT '<literal>'` echoes its literal (the sentinel), anything
# else answers from $STUB_ROWS = {substring: [[cell, ...], ...]} (first matching key; no match = no rows).
# STUB_MODE: fail = exit 1 before any output; cut = stop after the first statement (exit 0, output truncated);
#            die-mid = print the first statement's rows then exit 1; extra = one more row after the last sentinel.
STUB = r'''#!/usr/bin/env python3
import json, os, re, sys
sql = sys.stdin.read()
with open(os.environ["STUB_CALLS"], "a") as fh:
    fh.write(json.dumps(sql) + "\n")
mode = os.environ.get("STUB_MODE", "")
if mode == "fail":
    sys.stdout.write("WARNING: half a line\n")
    sys.stderr.write("Query 2026_x failed: replica is under too much load\n"); sys.exit(1)
rows = json.loads(os.environ.get("STUB_ROWS", "{}"))
def out(r): print(",".join('"' + c.replace('"', '""') + '"' for c in r))
for i, st in enumerate(sql.split("\n;\n")):
    m = re.fullmatch(r"\s*SELECT '([^']*)'\s*", st)
    if m:
        out([m.group(1)])
    else:
        for k, rs in rows.items():
            if k in st:
                for r in rs: out(r)
                break
    if mode == "cut" and i == 0: sys.exit(0)
    if mode == "die-mid" and i == 0:
        sys.stderr.write("Query 2026_y failed: line 1:8: Column 'nope' cannot be resolved\n"); sys.exit(1)
if mode == "extra": out(["straggler"])
'''


class Replica:
    """The stand-in wrapper on disk plus what it was asked."""

    def __init__(self, tmp: str, name: str = "trino-query.sh"):
        self.cmd = os.path.join(tmp, name)
        self.calls_path = os.path.join(tmp, "calls")
        Path(self.cmd).write_text(STUB)
        os.chmod(self.cmd, 0o755)
        Path(self.calls_path).write_text("")

    def env(self, rows: dict | None = None, mode: str = "") -> dict:
        return dict(os.environ, STUB_CALLS=self.calls_path, STUB_ROWS=json.dumps(rows or {}), STUB_MODE=mode)

    def calls(self) -> list[str]:
        return [json.loads(ln) for ln in Path(self.calls_path).read_text().splitlines() if ln]

    def reset(self) -> None:
        Path(self.calls_path).write_text("")


def all_planned(campaign, copy, uid, keys, **kw) -> set[str]:
    return set(gate_facts.plan(campaign, copy, uid, keys, **kw))


def through(facts: dict[str, list[list[str]]], live):
    """A helper's `query` when its replica command is replica-serve.sh: the read's answer for an exact text, else live."""
    return lambda sql: [list(r) for r in facts[sql]] if sql in facts else live(sql)


class ReadManyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.rep = Replica(self.tmp)
        self._env = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)

    def go(self, stmts, rows=None, mode=""):
        os.environ.update(self.rep.env(rows, mode))
        return rb.read_many(stmts, cmd=self.rep.cmd)

    def test_every_statement_in_one_invocation_rows_in_order(self):
        got = self.go(["SELECT a FROM t1", "SELECT b FROM t2", "SELECT c FROM t3"],
                      {"t1": [["1", "x,y"], ["2", 'q"z']], "t3": [["9"]]})
        self.assertEqual(got, [[["1", "x,y"], ["2", 'q"z']], [], [["9"]]])
        self.assertEqual(len(self.rep.calls()), 1)                       # ONE round trip for three questions

    def test_rows_parse_exactly_as_the_single_statement_readers_parse_them(self):
        rows = {"credit_requests": [["42", '{"noticeSentAt":"2026-11-10T00:00:00Z"}', "", "", "2026-11-01 00:00:00.000 UTC"]]}
        os.environ.update(self.rep.env(rows))
        sql = gate_facts.core_notice_statements(42)[0]
        core_notice.TRINO, keep = self.rep.cmd, core_notice.TRINO
        try:
            self.assertEqual(rb.read_many([sql], cmd=self.rep.cmd)[0], core_notice.trino(sql))
        finally:
            core_notice.TRINO = keep

    def test_a_failed_batch_returns_nothing(self):
        with self.assertRaises(rb.BatchError):
            self.go(["SELECT a FROM t1", "SELECT b FROM t2"], {"t1": [["1"]]}, mode="fail")

    def test_a_statement_that_errors_midway_is_never_a_partial_answer(self):
        # the CLI stops at the first failing statement; the rows it already printed must not be returned
        with self.assertRaises(rb.BatchError):
            self.go(["SELECT a FROM t1", "SELECT nope FROM t2"], {"t1": [["1"]]}, mode="die-mid")

    def test_truncated_output_with_exit_zero_is_refused(self):
        with self.assertRaises(rb.BatchError) as ctx:
            self.go(["SELECT a FROM t1", "SELECT b FROM t2"], {"t1": [["1"]], "t2": [["2"]]}, mode="cut")
        self.assertIn("of 2 statement", str(ctx.exception))

    def test_rows_after_the_last_statement_are_refused(self):
        with self.assertRaises(rb.BatchError):
            self.go(["SELECT a FROM t1"], {"t1": [["1"]]}, mode="extra")

    def test_a_statement_carrying_a_separator_is_never_batched(self):
        self.assertFalse(rb.batchable("SELECT 1; SELECT 2"))
        with self.assertRaises(rb.BatchError):
            self.go(["SELECT 1; DROP TABLE x"])
        self.assertEqual(self.rep.calls(), [])                           # refused before the replica is asked
        self.assertEqual(rb.unique(["a", "a", "b;c", "", "d"]), ["a", "d"])

    def test_a_data_row_cannot_pose_as_a_sentinel(self):
        # a row that LOOKS like a sentinel but does not carry this call's nonce is data, wherever it lands
        fake = "<<replica-batch 00000000000000000000000000000000 0>>"
        got = self.go(["SELECT a FROM t1", "SELECT b FROM t2"], {"t1": [[fake]], "t2": [["2"]]})
        self.assertEqual(got, [[[fake]], [["2"]]])

    def test_a_trailing_line_comment_cannot_swallow_the_separator(self):
        script = rb.script(["SELECT 1 -- note", "SELECT 2"], "n")
        self.assertIn("-- note\n;\n", script)

    def test_a_missing_wrapper_is_a_batch_error(self):
        with self.assertRaises(rb.BatchError):
            rb.read_many(["SELECT 1"], cmd=os.path.join(self.tmp, "nope.sh"))

    def test_nothing_to_ask_asks_nothing(self):
        self.assertEqual(rb.read_many([], cmd=self.rep.cmd), [])
        self.assertEqual(self.rep.calls(), [])


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def b(self, **over):
        obj = rb.bundle(["SELECT 1", "SELECT 2"], [[["1"]], []], 1000.0)
        obj.update(over)
        return json.dumps(obj)

    def on_file(self, text: str) -> str:
        path = os.path.join(self.tmp, "facts")
        Path(path).write_text(text)
        return path

    def test_round_trip(self):
        self.assertEqual(rb.load(self.b(), now=1005.0), {"SELECT 1": [["1"]], "SELECT 2": []})

    def test_stale_future_wrong_version_or_malformed_is_not_a_bundle(self):
        self.assertIsNone(rb.load(self.b(), now=1000.0 + rb.MAX_AGE_S + 1))      # stale
        self.assertIsNone(rb.load(self.b(), now=990.0))                          # stamped in the future
        self.assertIsNone(rb.load(self.b(replica_batch=2), now=1001.0))
        self.assertIsNone(rb.load(self.b(read_at="1000"), now=1001.0))
        self.assertIsNone(rb.load(self.b(read_at=True), now=1001.0))
        self.assertIsNone(rb.load(self.b(statements=[["SELECT 1", [["1", 2]]]]), now=1001.0))   # a non-text cell
        self.assertIsNone(rb.load(self.b(statements=[["SELECT 1"]]), now=1001.0))
        self.assertIsNone(rb.load(self.b(statements={"SELECT 1": []}), now=1001.0))
        for junk in ("", "not json", "[]", "null", '{"hold": false}'):
            self.assertIsNone(rb.load(junk, now=1001.0))

    def test_one_answer_per_statement(self):
        with self.assertRaises(rb.BatchError):
            rb.bundle(["a", "b"], [[]], 1.0)

    def test_answer_is_only_ever_the_exact_text(self):
        path = self.on_file(self.b())
        self.assertEqual(rb.answer(path, "SELECT 1", now=1001.0), [["1"]])
        self.assertEqual(rb.answer(path, "SELECT 2", now=1001.0), [])     # an EMPTY answer is an answer, not a miss
        self.assertIsNone(rb.answer(path, "SELECT 1 ", now=1001.0))       # one byte different = a different question
        self.assertIsNone(rb.answer(path, "SELECT 3", now=1001.0))

    def test_no_read_a_stale_one_or_a_bad_one_answers_nothing(self):
        self.assertIsNone(rb.answer("", "SELECT 1"))
        self.assertIsNone(rb.answer(os.path.join(self.tmp, "gone"), "SELECT 1"))
        self.assertIsNone(rb.answer(self.tmp, "SELECT 1"))                               # a directory
        self.assertIsNone(rb.answer(self.on_file(self.b()), "SELECT 1", now=1000.0 + rb.MAX_AGE_S + 1))
        self.assertIsNone(rb.answer(self.on_file("garbage"), "SELECT 1", now=1001.0))
        Path(os.path.join(self.tmp, "bin")).write_bytes(b"\xff\xfe\x00")
        self.assertIsNone(rb.answer(os.path.join(self.tmp, "bin"), "SELECT 1", now=1001.0))

    def test_rows_that_would_not_read_back_identically_are_never_served(self):
        for rows in ([["a\nb"]], [[]], [["x"], []]):
            self.assertFalse(rb.round_trips(rows))
            path = self.on_file(json.dumps(rb.bundle(["SELECT 1"], [rows], 1000.0)))
            self.assertIsNone(rb.answer(path, "SELECT 1", now=1001.0))
        for rows in ([], [["", "x,y", 'q"z', " lead", "'s", "é"]], [["1"], ["2"]]):
            self.assertTrue(rb.round_trips(rows))
            buf = io.StringIO()
            rb.write_csv(rows, buf)
            self.assertEqual(rb.parse(buf.getvalue().splitlines()), rows)

    def test_a_read_names_its_user_in_every_statement(self):
        # the property that keeps one person's read from answering about another: the id is in the text
        self.assertFalse(all_planned("uvn-status", "uvn", 42, [REQ]) & all_planned("uvn-status", "uvn", 43, [REQ]))
        self.assertFalse(all_planned("claim-status", "pending", 42, ["claim-7"])
                         & all_planned("claim-status", "pending", 43, ["claim-7"]))


class Stores:
    """comm_state's own stores, pointed at temp files (the pattern test_comm_state.py uses)."""

    def __init__(self, tmp: str):
        self.keep = (cs.LEDGER, cs.PROOF_STORE, cs.DV_STORE, cs.PROOF_ON_FILE, cs.POLICIES, cs.ACCOUNT_HOLDS,
                     cs.ACCOUNT_BANDS, gate_facts.POLICIES)
        cs.LEDGER = os.path.join(tmp, "ledger.sqlite3")
        vl.connect(cs.LEDGER).close()
        cs.ACCOUNT_HOLDS = os.path.join(tmp, "account_holds.jsonl")     # a fresh, empty hold ledger: nobody held
        Path(cs.ACCOUNT_HOLDS).write_text("")
        cs.ACCOUNT_BANDS = os.path.join(tmp, "account_bands.json")
        cs.PROOF_STORE = os.path.join(tmp, "proof.sqlite")
        con = sqlite3.connect(cs.PROOF_STORE)
        con.execute("CREATE TABLE proof_intake (user_id INTEGER, file_sha256 TEXT, received_at TEXT DEFAULT '')")
        con.commit(); con.close()
        cs.DV_STORE = os.path.join(tmp, "dv.sqlite")
        con = sqlite3.connect(cs.DV_STORE)
        con.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, request_id TEXT, "
                    "proof_id TEXT, need TEXT, outcome TEXT, at TEXT DEFAULT '2026-10-20T00:00:00Z')")
        con.commit(); con.close()
        cs.PROOF_ON_FILE = os.path.join(tmp, "pof.json")
        Path(cs.PROOF_ON_FILE).write_text(json.dumps({"entries": []}))
        cs.POLICIES = gate_facts.POLICIES = str(ROOT / "policies")   # the lens reads the real watchlist + holds

    def dv(self, request_id: str, outcome: str) -> None:
        con = sqlite3.connect(cs.DV_STORE)
        con.execute("INSERT INTO dv_outcomes (user_id, request_id, proof_id, need, outcome) VALUES (?,?,?,?,?)",
                    (UID, request_id, "p1", "readable_document", outcome))
        con.commit(); con.close()

    def restore(self) -> None:
        (cs.LEDGER, cs.PROOF_STORE, cs.DV_STORE, cs.PROOF_ON_FILE, cs.POLICIES, cs.ACCOUNT_HOLDS,
         cs.ACCOUNT_BANDS, gate_facts.POLICIES) = self.keep

    def env(self) -> dict:
        """The same stores for a `python3 -I comm_state.py` subprocess."""
        return {"COMM_STATE_LEDGER": cs.LEDGER, "COMM_STATE_PROOF_STORE": cs.PROOF_STORE,
                "COMM_STATE_DV_STORE": cs.DV_STORE, "COMM_STATE_PROOF_ON_FILE": cs.PROOF_ON_FILE,
                "COMM_STATE_POLICIES": cs.POLICIES, "COMM_STATE_ACCOUNT_HOLDS": cs.ACCOUNT_HOLDS,
                "COMM_STATE_ACCOUNT_BANDS": cs.ACCOUNT_BANDS}


def answer(sql: str) -> list[list[str]]:
    """A replica that answers every statement of these checks with well-formed rows for one quiet account."""
    if "proof_required_owed" in sql:
        return [["0", "0"]]
    if "max(n)" in sql or "lower(email)" in sql or "claiming" in sql:
        return []
    if "'$.approvedNotice.noticeSentAt'" in sql:                 # comm_state.core_facts
        return [[REQ, "user_verification_needed", "", "", OLD]]
    return []


def no_intercom(method, path, body=None):
    return {"conversations": [], "total_count": 0}



class PlanIsCompleteTests(unittest.TestCase):
    """The helpers are not changed by this, so gate_facts.py holds its own copy of their statement text. These run
    the REAL helper functions against a recording replica: a statement either of them asks that the plan does not
    list (a new read, or one whose text moved by a byte) fails here."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.stores = Stores(self.tmp)

    def tearDown(self):
        self.stores.restore()

    def asked(self, campaign, copy, keys, world=None, **kw) -> list[str]:
        asked: list[str] = []

        def q(sql):
            asked.append(sql)
            return (world or answer)(sql)
        core_notice.reasons_by_user([UID], query=q)
        cs.check(campaign, copy, UID, list(keys), "c1", query=q, ic=no_intercom, **kw)
        return asked

    def test_the_sent_families_are_fully_predicted(self):
        for campaign, copy, keys in (("uvn-status", "uvn", [REQ]),
                                     ("status-team-review", "count", [REQ]),
                                     ("claim-status", "pending", ["claim-7"]),
                                     ("claim-proof-ask", "initial", ["claim-7"]),
                                     ("status-doc-received", "docrecv", [REQ]),
                                     ("gap-ask", "gap", [REQ]),
                                     ("verify-live", "v1", [REQ])):
            with self.subTest(campaign=campaign):
                asked = self.asked(campaign, copy, keys)
                self.assertTrue(asked)
                self.assertEqual([s for s in asked if s not in all_planned(campaign, copy, UID, keys)], [])

    def test_uvn_status_is_one_round_trip_for_what_used_to_be_five_or_six(self):
        plan = gate_facts.plan("uvn-status", "uvn", UID, [REQ])
        asked = self.asked("uvn-status", "uvn", [REQ])
        self.assertGreaterEqual(len(asked), 4)                         # core_notice 2 + core_facts + the lens reads
        self.assertEqual(sorted(set(asked)), sorted(plan))             # exactly these: nothing extra is prefetched
        self.assertEqual(len(plan), len(set(plan)))

    def test_the_approval_path_read_is_predicted(self):
        # an account whose only reason is an open UVN request: owes_proof asks the approval-path read
        def world(sql):
            if "regexp_like" in sql and "status IN ('user_verification_needed', 'unverified')" in sql:
                return [["user_verification_needed", "false"]]
            return answer(sql)
        asked = self.asked("status-team-review", "count", [REQ], world=world)
        approval = uvn_status.uvn_requests_sql([UID], ("user_verification_needed",))
        self.assertIn(approval, asked)
        self.assertEqual([s for s in asked if s not in all_planned("status-team-review", "count", UID, [REQ])], [])

    def test_the_doc_verify_follow_up_is_the_one_read_left_live(self):
        self.stores.dv(REQ, "unverifiable")
        asked = self.asked("status-team-review", "count", [REQ])
        left = [s for s in asked if s not in all_planned("status-team-review", "count", UID, [REQ])]
        self.assertEqual(len(left), 1)
        self.assertIn("IN ('" + REQ + "')", left[0])

    def test_a_reply_due_answer_reads_no_core_notice_statements(self):
        planned = all_planned("uvn-status", "uvn", UID, [REQ], reply_due_part="123")
        self.assertFalse(set(gate_facts.core_notice_statements(UID)) & planned)
        self.assertTrue(set(gate_facts.core_facts_statements(UID, [REQ])) <= planned)
        self.assertTrue(set(gate_facts.owes_statements(UID)) <= planned)

    def test_the_copied_rules_equal_comm_states(self):
        self.assertEqual(gate_facts.REVIEW_FIRED, cs.REVIEW_FIRED)
        self.assertEqual(gate_facts.RECEIPT, cs.RECEIPT)
        for campaign in ("status-team-review", "claim-status", cs.RECEIPT, "uvn-status", "gap-ask", "verify-live",
                         "claim-proof-ask", "proof-need-ask", "uvn-new-rows", ""):
            for copy in ("docrecv", "docrecvq", "count", "uvn", "initial", ""):
                self.assertEqual(gate_facts.nothing_else(campaign, copy), cs.nothing_else(campaign, copy))
        src = (CR / "comm_state.py").read_text()
        self.assertIn('POLICIES = os.environ.get("COMM_STATE_POLICIES", "/opt/hydra/policies")', src)
        self.assertIn('os.environ.get("COMM_STATE_POLICIES", "/opt/hydra/policies")',
                      (CR / "gate_facts.py").read_text())

    def test_the_lens_is_listed_with_the_lens_own_builders(self):
        asked: list[str] = []
        lens = fraud_lens.default_lens(lambda sql: asked.append(sql) or [],
                                       watchlist_path=str(ROOT / "policies" / "fraud-watchlist.json"),
                                       holds_path=str(ROOT / "policies" / "fraud-lens-holds.json"))
        lens([UID])
        self.assertEqual(asked, lens.statements([UID]))
        self.assertTrue(asked)
        self.assertEqual(gate_facts.lens_statements(UID), asked)       # cs.POLICIES is the repo's here

    def test_a_plan_that_cannot_list_the_lens_still_lists_the_rest(self):
        keep, gate_facts.POLICIES = gate_facts.POLICIES, os.path.join(self.tmp, "no-policies")
        try:
            planned = all_planned("uvn-status", "uvn", UID, [REQ])
        finally:
            gate_facts.POLICIES = keep
        self.assertTrue(set(gate_facts.core_notice_statements(UID)) <= planned)
        self.assertTrue(set(gate_facts.core_facts_statements(UID, [REQ])) <= planned)

    def test_the_batch_goes_to_the_wrapper_beside_this_tree(self):
        self.assertEqual(gate_facts.REPLICA, str(ROOT / "scripts" / "trino-query.sh"))
        src = (CR / "gate_facts.py").read_text()
        for seam in ("CORE_NOTICE_TRINO", "COMM_STATE_TRINO", "TRINO_CMD"):
            self.assertNotIn(seam, src)                                 # nothing a caller sets picks the wrapper


class SameAnswerTests(unittest.TestCase):
    """With the read or without it, the helpers return the same answer."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.stores = Stores(self.tmp)

    def tearDown(self):
        self.stores.restore()

    def test_check_through_the_read_equals_check_live(self):
        recent = (datetime.now(timezone.utc) - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        core = gate_facts.core_facts_statements(UID, [REQ])[0]
        owes = gate_facts.owes_statements(UID)[0]
        worlds = {
            "quiet": answer,
            "approved-and-told": lambda sql: [[REQ, "approved", recent, "", OLD]] if sql == core else answer(sql),
            "owes-uvn": lambda sql: [["user_verification_needed", "false"]] if sql == owes else answer(sql),
            "review-hold": lambda sql: [["unverified", "true"]] if sql == owes else answer(sql),
        }
        for name, world in worlds.items():
            for campaign, copy in (("uvn-status", "uvn"), ("status-team-review", "count")):
                with self.subTest(world=name, campaign=campaign):
                    live = cs.check(campaign, copy, UID, [REQ], "c1", query=world, ic=no_intercom)
                    stmts = gate_facts.plan(campaign, copy, UID, [REQ])
                    facts = rb.load(rb.dumps(rb.bundle(stmts, [world(s) for s in stmts], time.time())))

                    def boom(sql):
                        raise AssertionError(f"read live with a complete read on file: {sql[:80]}")
                    self.assertEqual(cs.check(campaign, copy, UID, [REQ], "c1", query=through(facts, boom),
                                              ic=no_intercom), live)
        self.assertTrue(cs.check("status-team-review", "count", UID, [REQ], "c1", query=worlds["review-hold"],
                                 ic=no_intercom)["hold"])               # the worlds are not all "clear"

    def test_core_notice_through_the_read_equals_core_notice_live(self):
        recent = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        stmts = gate_facts.core_notice_statements(UID)

        def world(sql):
            return [[str(UID), json.dumps({"noticeSentAt": recent}), "", "", OLD]] if sql == stmts[0] else []
        live = core_notice.reasons_by_user([UID], query=world)
        self.assertEqual(live[UID], ["approvedNotice within 7d"])
        facts = rb.load(rb.dumps(rb.bundle(stmts, [world(s) for s in stmts], time.time())))
        self.assertEqual(core_notice.reasons_by_user([UID], query=through(facts, lambda sql: 1 / 0)), live)


class CliTests(unittest.TestCase):
    """The files exactly as the gate runs them: gate_facts.py and the two UNCHANGED helpers as `python3 -I <file>`,
    the helpers' replica command set to replica-serve.sh. The tree is a copy with the stand-in as its trino-query.sh,
    because both new files find the real wrapper from their own location and take no path from a caller."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.tree = os.path.join(self.tmp, "scripts")
        shutil.copytree(CR, os.path.join(self.tree, "credit_review"), ignore=shutil.ignore_patterns("__pycache__"))
        os.symlink(ROOT / "scripts" / "lib", os.path.join(self.tree, "lib"))     # what credit_review imports
        shutil.copy2(ROOT / "scripts" / "replica-serve.sh", self.tree)
        self.serve = os.path.join(self.tree, "replica-serve.sh")
        self.rep = Replica(self.tree)                                   # <tree>/trino-query.sh
        self.facts = os.path.join(self.tmp, "facts")
        recent = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.rows = {"$.approvedNotice')": [[str(UID), json.dumps({"noticeSentAt": recent}), "", "", OLD]],
                     "proof_required_owed": [["0", "0"]]}
        self.stores = Stores(self.tmp)
        self.store_env = self.stores.env()
        self.stores.restore()

    def run_(self, name, *args, rows=None, mode="", served=False, env=None):
        e = self.rep.env(self.rows if rows is None else rows, mode)
        e.update(self.store_env)
        if served:        # what with_gate_facts() sets in the gate
            e.update(CORE_NOTICE_TRINO=self.serve, COMM_STATE_TRINO=self.serve, REPLICA_BATCH_FACTS=self.facts)
        else:             # the helpers' own default, pointed at the stand-in
            e.update(CORE_NOTICE_TRINO=self.rep.cmd, COMM_STATE_TRINO=self.rep.cmd)
        e.update(env or {})
        return subprocess.run([sys.executable, "-I", os.path.join(self.tree, "credit_review", name), *args], env=e,
                              capture_output=True, text=True, timeout=120)

    def read(self, campaign="uvn-status", copy="uvn", uid=UID, **kw):
        p = self.run_("gate_facts.py", "read", "--campaign", campaign, "--copy", copy, "--user-id", str(uid),
                      "--request-ids", REQ, **kw)
        Path(self.facts).write_text(p.stdout)
        return p

    def test_one_round_trip_for_the_person_then_core_notice_makes_none(self):
        live = self.run_("core_notice.py", "check", "--user-id", str(UID))
        self.assertEqual(live.returncode, 3, live.stderr)
        self.assertEqual(len(self.rep.calls()), 2)                     # before: two round trips for this one helper
        self.rep.reset()
        p = self.read()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(self.rep.calls()), 1)                     # the whole person: ONE round trip
        self.rep.reset()
        fast = self.run_("core_notice.py", "check", "--user-id", str(UID), served=True)
        self.assertEqual((fast.returncode, json.loads(fast.stdout)), (live.returncode, json.loads(live.stdout)))
        self.assertEqual(self.rep.calls(), [])                         # after: none of its own

    def test_a_stale_garbage_or_missing_read_is_run_live_with_the_same_answer(self):
        p = self.read()
        stale = json.loads(p.stdout)
        stale["read_at"] -= 3600
        for text in (json.dumps(stale), "garbage", "", '{"hold": false, "reasons": []}', None):
            with self.subTest(text=str(text)[:20]):
                if text is None:
                    os.remove(self.facts)
                else:
                    Path(self.facts).write_text(text)
                self.rep.reset()
                got = self.run_("core_notice.py", "check", "--user-id", str(UID), served=True)
                self.assertEqual(got.returncode, 3)                    # the HOLD is still found
                self.assertEqual(len(self.rep.calls()), 2)             # by asking the replica itself

    def test_a_read_for_another_person_answers_nothing(self):
        other = self.read(uid=43, rows={})                             # user 43: no notice at all
        self.assertEqual(other.returncode, 0, other.stderr)
        self.rep.reset()
        got = self.run_("core_notice.py", "check", "--user-id", str(UID), served=True)
        self.assertEqual(got.returncode, 3)                            # 42's hold, read live: 43's "clear" never applied
        self.assertEqual(len(self.rep.calls()), 2)

    def test_a_failed_read_prints_nothing(self):
        for mode in ("fail", "die-mid", "cut", "extra"):
            with self.subTest(mode=mode):
                p = self.read(mode=mode)
                self.assertEqual((p.returncode, p.stdout), (2, ""))
        p = self.run_("gate_facts.py", "read", "--campaign", "uvn-status", "--user-id", "jane@example.com")
        self.assertEqual((p.returncode, p.stdout), (2, ""))

    def test_an_unreadable_replica_is_still_unknown_never_clear(self):
        # the batch fails -> nothing on file -> the helper's statements run live -> they fail -> exit 2, as before
        self.read(mode="fail")
        got = self.run_("core_notice.py", "check", "--user-id", str(UID), served=True, mode="fail")
        self.assertEqual(got.returncode, 2)

    def test_a_statement_not_on_file_is_the_real_wrappers_answer_byte_for_byte(self):
        e = self.rep.env({"t1": [["1", "x,y"]]})
        e["REPLICA_BATCH_FACTS"] = self.facts
        direct = subprocess.run([self.rep.cmd], input="SELECT a FROM t1", env=e, capture_output=True, text=True)
        via = subprocess.run([self.serve], input="SELECT a FROM t1", env=e, capture_output=True, text=True)
        self.assertEqual((via.returncode, via.stdout, via.stderr), (direct.returncode, direct.stdout, direct.stderr))
        self.assertEqual(via.stdout, '"1","x,y"\n')
        e["STUB_MODE"] = "fail"
        direct = subprocess.run([self.rep.cmd], input="SELECT a FROM t1", env=e, capture_output=True, text=True)
        via = subprocess.run([self.serve], input="SELECT a FROM t1", env=e, capture_output=True, text=True)
        self.assertEqual((via.returncode, via.stdout, via.stderr), (direct.returncode, direct.stdout, direct.stderr))
        self.assertEqual(via.returncode, 1)
        big = "SELECT a FROM t1 WHERE x IN (" + ",".join(["1"] * 40000) + ")"       # larger than a pipe holds
        e["STUB_MODE"] = ""
        via = subprocess.run([self.serve], input=big, env=e, capture_output=True, text=True)
        self.assertEqual((via.returncode, via.stdout), (0, '"1","x,y"\n'))
        self.assertEqual(self.rep.calls()[-1], big)

    def test_replica_serve_finds_the_wrapper_from_its_own_location_only(self):
        other = Replica(tempfile.mkdtemp(), "elsewhere.sh")
        e = self.rep.env({"t1": [["mine"]]})
        e.update(REPLICA_BATCH_FACTS="", CORE_NOTICE_TRINO=other.cmd, COMM_STATE_TRINO=other.cmd, TRINO=other.cmd)
        link = os.path.join(tempfile.mkdtemp(), "replica-serve.sh")
        os.symlink(self.serve, link)                                    # a link in a caller's tree: still this tree
        via = subprocess.run([link], input="SELECT a FROM t1", env=e, capture_output=True, text=True)
        self.assertEqual((via.returncode, via.stdout), (0, '"mine"\n'))
        self.assertEqual(len(self.rep.calls()), 1)

    def test_comm_state_through_the_read_asks_the_replica_nothing(self):
        # the owes-nothing family: no Intercom read in this check, so the whole helper runs here as the gate runs it
        pol = {"COMM_STATE_POLICIES": str(ROOT / "policies")}
        args = ("check", "--campaign", "status-team-review", "--copy", "count", "--user-id", str(UID),
                "--request-ids", REQ, "--contact-id", "c1")
        for name, rows in (("clear", self.rows),
                           ("owes", dict(self.rows, regexp_like=[["user_verification_needed", "false"]]))):
            with self.subTest(world=name):
                self.rep.reset()
                live = self.run_("comm_state.py", *args, rows=rows, env=pol)
                self.assertEqual(live.returncode, 3 if name == "owes" else 0, live.stdout + live.stderr)
                self.assertGreaterEqual(len(self.rep.calls()), 2)      # live: one round trip per question
                p = self.read(campaign="status-team-review", copy="count", rows=rows, env=pol)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.rep.reset()
                fast = self.run_("comm_state.py", *args, rows=rows, served=True, env=pol)
                self.assertEqual((fast.returncode, json.loads(fast.stdout)), (live.returncode, json.loads(live.stdout)))
                self.assertEqual(self.rep.calls(), [])                 # through the read: none


if __name__ == "__main__":
    unittest.main()
