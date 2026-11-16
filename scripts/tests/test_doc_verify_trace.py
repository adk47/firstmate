#!/usr/bin/env python3
"""doc-verify leaves a record, and its words mean the same thing to everyone who reads them.

Two things are pinned here.

1. THE TRACE GUARD. `dv_outcomes` (with `dv_steps`) in the doc-verify store is the store of record for
   what doc-verify decides. `credit-doc-verify.py run` reads back the rows on file under its run id and
   exits non-zero when it processed documents and wrote none, or judged more claims than it has outcome
   rows (`runner.untraced`, `store.run_rows`).

2. THE OUTCOME VOCABULARY. The gate emits six outcome words and other jobs read them as string literals
   in their own files, so nothing but a test ties the two sides together. `EMITTED` is the gate's side,
   `READERS` is every file that reads `dv_outcomes` with the outcome words it names, and `MAPS` is the
   position each translating reader takes on every word. An edit to either side fails here until the
   other side is looked at.

`proof_verifications` (scripts/credit_review/proof_verifications.py) is NOT part of this: it is the
credit-removal executor's proof-link table with its own verdict words, and doc-verify never writes it.

Synthetic data only; the model, the network and the admin API are faked.

    python3 scripts/tests/test_doc_verify_trace.py
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import sqlite3
import sys
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_doc_verify as base  # noqa: E402 - the runner fixture (a fake document, model, network)
from credit_verify.docverify import gate, runner  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402

SINCE = "2026-10-27T00:00:00Z"


def load_cli():
    spec = importlib.util.spec_from_file_location("cdv_trace", SCRIPTS / "credit-doc-verify.py")
    cdv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cdv)
    return cdv


# -- 1. the trace guard ----------------------------------------------------------------------------------

class UntracedRuleTests(unittest.TestCase):
    """runner.untraced: the two facts that fail a run, and the runs that are not failures."""

    def stats(self, **kw) -> runner.Stats:
        st = runner.Stats("dv-test-run")
        for k, v in kw.items():
            setattr(st, k, v)
        return st

    def test_documents_processed_and_zero_rows_written_fails_and_names_the_fact(self):
        why = runner.untraced(self.stats(documents=400), steps=0, outcomes=0)
        self.assertIsNotNone(why)
        self.assertIn("processed 400 document(s) and wrote zero rows", why)
        self.assertIn("dv-test-run", why)

    def test_a_run_that_processed_nothing_owes_nothing(self):
        self.assertIsNone(runner.untraced(self.stats(), steps=0, outcomes=0))
        self.assertIsNone(runner.untraced(self.stats(keyed=7), steps=7, outcomes=0))

    def test_rows_on_file_with_no_outcome_is_not_a_failure(self):
        # claim-only filings are read for their extraction; a retried or closed document has no verdict yet
        self.assertIsNone(runner.untraced(self.stats(documents=3, claim_only=3), steps=9, outcomes=0))
        self.assertIsNone(runner.untraced(self.stats(documents=2, retry=2), steps=4, outcomes=0))

    def test_every_judged_claim_needs_its_outcome_row(self):
        for outcomes in (0, 4):
            why = runner.untraced(self.stats(documents=2, pairs=5), steps=40, outcomes=outcomes)
            self.assertIsNotNone(why, outcomes)
            self.assertIn("judged 5 claim(s)", why)
            self.assertIn(f"{outcomes} dv_outcomes row(s)", why)
        self.assertIsNone(runner.untraced(self.stats(documents=2, pairs=5), steps=40, outcomes=5))

    def test_a_superseded_verified_row_is_a_row_owed_too(self):
        st = self.stats(documents=1, pairs=5, superseded=2)
        self.assertIsNone(runner.untraced(st, steps=30, outcomes=7))
        self.assertIn("judged 7 claim(s)", runner.untraced(st, steps=30, outcomes=6))

    def test_a_filing_whose_bytes_went_missing_is_owed_no_row(self):
        # verify_document records nothing for it on purpose (`blob_owed`), so a run of only those is not silent
        self.assertIsNone(runner.untraced(self.stats(documents=2, blob_owed=2), steps=0, outcomes=0))
        self.assertIsNotNone(runner.untraced(self.stats(documents=3, blob_owed=2), steps=0, outcomes=0))


class TraceOnFileTests(unittest.TestCase):
    """A real run through the fixture: the rows are on file, and they are read from the file."""
    setUp = base.RunnerTests.setUp
    tearDown = base.RunnerTests.tearDown

    def test_a_run_writes_its_verdict_and_its_steps_under_its_run_id(self):
        stats, rows = runner.run(self.store, self.deps, proof_store=self.proof_path, since=SINCE)
        self.assertEqual((stats.documents, stats.pairs), (1, 1))
        steps, outcomes = self.store.run_rows(stats.run_id)
        self.assertGreater(steps, 0)
        self.assertEqual(outcomes, 1)
        self.assertIsNone(runner.untraced(stats, steps, outcomes))
        # the row is readable afterwards by anyone who opens the file, with the verdict the run reported
        other = sqlite3.connect(f"file:{self.store.path}?mode=ro", uri=True)
        try:
            got = other.execute("SELECT run_id, proof_id, request_id, role, outcome FROM dv_outcomes").fetchall()
        finally:
            other.close()
        self.assertEqual(got, [(stats.run_id, self.proof_id, base.RID, "Mixing", rows[0]["outcome"])])

    def test_another_runs_rows_do_not_count_for_this_run(self):
        stats, _ = runner.run(self.store, self.deps, proof_store=self.proof_path, since=SINCE)
        self.assertEqual(self.store.run_rows("dv-some-other-run"), (0, 0))
        again, _ = runner.run(self.store, self.deps, proof_store=self.proof_path, since=SINCE)
        self.assertEqual(again.documents, 0)                      # nothing left to read: nothing owed
        self.assertEqual(self.store.run_rows(again.run_id)[1], 0)
        self.assertIsNone(runner.untraced(again, *self.store.run_rows(again.run_id)))

    def test_a_write_that_never_reached_the_file_is_not_counted(self):
        # the read-back opens the file again. A row the store's OWN connection holds in a transaction nobody
        # committed is visible to that connection and to no other reader: counting it would be the writer
        # vouching for itself.
        own = self.store.db
        own.execute("INSERT INTO dv_steps (run_id, at, proof_id, request_id, step, status, detail_json, version) "
                    "VALUES ('dv-open-tx', 't', 'p', '', 'locate', 'ok', '{}', 'dv-4')")
        self.assertTrue(own.in_transaction)
        self.assertEqual(own.execute("SELECT COUNT(*) FROM dv_steps WHERE run_id='dv-open-tx'").fetchone()[0], 1)
        self.assertEqual(self.store.run_rows("dv-open-tx"), (0, 0))
        own.commit()
        self.assertEqual(self.store.run_rows("dv-open-tx"), (1, 0))

    def test_a_store_file_that_is_gone_raises_instead_of_reading_as_zero(self):
        gone = DocVerifyStore(os.path.join(self.td.name, "gone", "dv.sqlite"))
        gone.step("dv-gone", "p", "locate", "ok", {})
        self.assertEqual(gone.run_rows("dv-gone"), (1, 0))
        gone.db.close()
        for name in os.listdir(os.path.dirname(gone.path)):
            os.unlink(os.path.join(os.path.dirname(gone.path), name))
        with self.assertRaises(sqlite3.Error):
            gone.run_rows("dv-gone")


class RunExitTests(unittest.TestCase):
    """`credit-doc-verify.py run`: the exit code and the line that names the fact."""
    setUp = base.RunnerTests.setUp
    tearDown = base.RunnerTests.tearDown

    def cli_run(self, cdv, *, run=None, patches=()):
        """cmd_run on the fixture's store and proof store; returns (exit code, logged lines)."""
        lines: list[str] = []
        args = cdv.parser().parse_args(["--store", self.store.path, "--proof-store", self.proof_path,
                                        "run", "--max-docs", "5", "--since", SINCE])
        with unittest.mock.patch.object(cdv, "real_deps", return_value=self.deps), \
                unittest.mock.patch.object(cdv, "paying_users", return_value=None), \
                unittest.mock.patch.object(cdv, "log", lines.append), \
                unittest.mock.patch.object(cdv, "KILL_SWITCH", os.path.join(self.td.name, "absent")), \
                unittest.mock.patch("builtins.print"):
            ctx = [unittest.mock.patch.object(runner, "run", run)] if run else []
            ctx += list(patches)
            for c in ctx:
                c.start()
            try:
                return cdv.cmd_run(args), lines
            finally:
                for c in reversed(ctx):
                    c.stop()

    def run_line(self, lines: list[str]) -> dict:
        return json.loads(next(ln for ln in lines if ln.startswith("run {"))[4:])

    def test_a_run_that_records_its_work_exits_zero_and_says_what_it_wrote(self):
        cdv = load_cli()
        rc, lines = self.cli_run(cdv)
        self.assertEqual(rc, 0, lines)
        line = self.run_line(lines)
        self.assertEqual((line["documents"], line["pairs"]), (1, 1))
        self.assertEqual(line["written"]["outcomes"], 1)
        self.assertGreater(line["written"]["steps"], 0)
        self.assertFalse([ln for ln in lines if "NO TRACE" in ln])

    def test_processed_documents_and_no_rows_written_exits_nonzero_and_names_it(self):
        # the failure this guard exists for: a run that says it processed 400 documents and left nothing
        cdv = load_cli()
        st = runner.Stats("dv-says-400")
        st.documents = 400
        rc, lines = self.cli_run(cdv, run=lambda *a, **k: (st, []))
        self.assertEqual(rc, cdv.EX_NO_TRACE)
        self.assertNotEqual(cdv.EX_NO_TRACE, 0)
        self.assertNotEqual(cdv.EX_NO_TRACE, cdv.EX_PROVIDER_DOWN)
        named = [ln for ln in lines if "NO TRACE" in ln]
        self.assertEqual(len(named), 1, lines)
        self.assertIn("run FAILED", named[0])
        self.assertIn("processed 400 document(s) and wrote zero rows", named[0])
        self.assertEqual(self.run_line(lines)["written"], {"steps": 0, "outcomes": 0})

    def test_a_real_run_whose_writes_go_nowhere_exits_nonzero(self):
        # the whole reader runs and judges; only the two writes of record are lost
        cdv = load_cli()
        rc, lines = self.cli_run(cdv, patches=(
            unittest.mock.patch.object(DocVerifyStore, "step", lambda *a, **k: None),
            unittest.mock.patch.object(DocVerifyStore, "outcome", lambda *a, **k: None)))
        self.assertEqual(rc, cdv.EX_NO_TRACE, lines)
        line = self.run_line(lines)
        self.assertEqual((line["documents"], line["pairs"]), (1, 1))      # it says it judged a claim
        self.assertEqual(line["written"], {"steps": 0, "outcomes": 0})     # and the file holds nothing
        self.assertIn("judged 1 claim(s) and 0 dv_outcomes row(s)", next(ln for ln in lines if "NO TRACE" in ln))

    def test_a_verdict_lost_while_its_steps_were_kept_exits_nonzero(self):
        cdv = load_cli()
        rc, lines = self.cli_run(cdv, patches=(
            unittest.mock.patch.object(DocVerifyStore, "outcome", lambda *a, **k: None),))
        self.assertEqual(rc, cdv.EX_NO_TRACE, lines)
        self.assertGreater(self.run_line(lines)["written"]["steps"], 0)

    def test_a_store_that_cannot_be_read_back_is_a_failure_not_a_pass(self):
        cdv = load_cli()

        def unreadable(self_, run_id):
            raise sqlite3.OperationalError("unable to open database file")
        rc, lines = self.cli_run(cdv, patches=(unittest.mock.patch.object(DocVerifyStore, "run_rows", unreadable),))
        self.assertEqual(rc, cdv.EX_NO_TRACE, lines)
        self.assertEqual(self.run_line(lines)["written"], {"steps": None, "outcomes": None})
        self.assertIn("could not be read back", next(ln for ln in lines if "NO TRACE" in ln))

    def test_a_provider_refusal_keeps_its_own_exit_code_and_the_missing_trace_is_still_named(self):
        cdv = load_cli()
        st = runner.Stats("dv-down")
        st.documents, st.provider_down = 3, "http 402"
        rc, lines = self.cli_run(cdv, run=lambda *a, **k: (st, []))
        self.assertEqual(rc, cdv.EX_PROVIDER_DOWN)
        self.assertTrue([ln for ln in lines if "NO TRACE" in ln], lines)

    def test_the_parent_of_parallel_workers_fails_and_names_the_silent_shard(self):
        import argparse
        import tempfile
        from credit_verify.docverify import pace
        cdv = load_cli()
        rcs = iter([0, cdv.EX_NO_TRACE, 0, 0])
        lines: list[str] = []

        class P:
            def __init__(self, argv):
                self.rc = next(rcs)

            def wait(self):
                return self.rc
        a = argparse.Namespace(store=None, proof_store="/p.sqlite", max_docs=8, since=None, workers=4)
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.object(pace, "PACE_DIR", d), \
                unittest.mock.patch.object(cdv, "log", lines.append):
            self.assertEqual(cdv.run_workers(a, popen=P), 1)
        self.assertIn("NO TRACE in shards [1]", lines[-1])


# -- 2. the outcome vocabulary ---------------------------------------------------------------------------

# What doc-verify writes in dv_outcomes.outcome. Changing this set changes what every reader below is told.
EMITTED = frozenset({"forged", "forged_positive", "contradicted", "verified", "unverifiable", "unknown"})

# Words that are doc-verify's wherever they appear as a whole string; `verified` and `unknown` are common
# words, so they count only where the code is plainly talking about an outcome (see `named`).
DISTINCTIVE = frozenset({"forged", "forged_positive", "contradicted", "unverifiable"})

GATE = "scripts/credit_verify/docverify/gate.py"
WRITERS = ("scripts/credit_verify/docverify/store.py", "scripts/credit_verify/docverify/runner.py")

# Every Python file outside the tests that names the table `dv_outcomes`, and the outcome words its source
# names. An empty set is a position too: the file reads rows, counts or ids and gives no word a meaning.
READERS: dict[str, frozenset[str]] = {
    "scripts/claim_verify/doc_sources.py": frozenset(),        # reads through doc_approve.BLOCKING_VERDICTS
    "scripts/credit-doc-verify.py": frozenset({"forged", "forged_positive", "contradicted", "verified"}),
    "scripts/credit_review/comm_state.py": frozenset({"unverifiable"}),
    "scripts/credit_review/doc_approve.py": frozenset({"contradicted", "forged", "verified"}),
    "scripts/credit_review/doc_close.py": frozenset({"forged_positive"}),
    "scripts/credit_review/fable_executor.py": frozenset({"forged"}),
    "scripts/credit_review/forged_tray.py": frozenset(),
    "scripts/credit_review/need_asks.py": frozenset({"unknown", "unverifiable"}),
    "scripts/credit_review/proof_reviewer.py": EMITTED,
    "scripts/credit_review/proposals.py": frozenset(),
    "scripts/credit_review/reply_due_scan.py": frozenset(),
    "scripts/credit_review/stage2_gap.py": frozenset(),  # names the table in prose; reads no outcome word
    "scripts/credit_verify/docverify/l11.py": frozenset({"forged", "forged_positive", "verified"}),
    "scripts/credit_verify/docverify/runner.py": frozenset(),  # writes what the gate returns; names no word
    "scripts/credit_verify/docverify/store.py": frozenset({"unknown", "unverifiable", "verified"}),
    "scripts/credit_verify/dspverify/d5b.py": frozenset({"verified"}),
    "scripts/intercom-backlog/drain.py": frozenset({"unverifiable"}),
    "scripts/ops_intake/answer.py": frozenset(),
    "scripts/ops_intake/proof_review.py": EMITTED - {"forged_positive"},
    "scripts/ops_intake/redteam.py": frozenset(),
    "scripts/ops_intake/router.py": frozenset(),
    "scripts/ops_intake/sources.py": frozenset({"verified", "contradicted", "forged", "unverifiable"}),
    "scripts/ops_intake/store.py": frozenset(),
    "scripts/verification-queue-report.py": frozenset(),
    "scripts/verifier_eval/verifiers.py": frozenset(),
}

# The readers that translate an outcome into another vocabulary. Each takes a position on EVERY emitted
# word: the ones it names, and the ones it leaves to a stated default. A new word must be placed in each.
MAPS: dict[str, dict[str, str]] = {
    "scripts/ops_intake/sources.py": {
        "unknown": "no entry in OUTCOME_WORDS: the reply carries the outcome upper-cased (UNKNOWN)",
        "forged_positive": "no entry in OUTCOME_WORDS: the reply carries the outcome upper-cased (FORGED_POSITIVE)",
    },
    "scripts/ops_intake/proof_review.py": {
        "forged_positive": "no DV_ constant: it matches no arm by name and falls to the rule's default",
    },
    "scripts/credit_review/proof_reviewer.py": {},
}

_SQL = re.compile(r"\boutcome\s*(?:=|<>|!=|(?:NOT\s+)?IN)\s*(\([^()]*\)|'[^']*')", re.I)
_DECLARES = re.compile(r"DV_|OUTCOME")


def _strings(node: ast.AST) -> set[str]:
    return {c.value for c in ast.walk(node) if isinstance(c, ast.Constant) and isinstance(c.value, str)}


def named(source: str, vocabulary: frozenset[str] = EMITTED) -> frozenset[str]:
    """The outcome words a reader's source names: a distinctive word as a whole string anywhere; any word in a
    comparison that mentions `outcome`, in SQL after `outcome =|<>|IN`, or in a `DV_*` / `*OUTCOME*` constant."""
    out: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if node.value in DISTINCTIVE:
                out.add(node.value)
            for m in _SQL.finditer(node.value):
                out |= set(re.findall(r"'(\w+)'", m.group(1)))
        elif isinstance(node, ast.Compare) and "outcome" in ast.unparse(node).lower():
            out |= _strings(node)
        elif isinstance(node, ast.Assign) and any(_DECLARES.search(ast.unparse(t)) for t in node.targets):
            out |= _strings(node.value)
    return frozenset(out & vocabulary)


def emitted(gate_source: str) -> frozenset[str]:
    """Every word the gate can return: the first argument of each `Outcome(...)` it builds, resolved through
    the module's own string constants. An argument that cannot be resolved raises: an unread word is not a pass."""
    tree = ast.parse(gate_source)
    consts: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                names = target.elts if isinstance(target, ast.Tuple) else [target]
                values = node.value.elts if isinstance(node.value, ast.Tuple) else [node.value]
                for n, v in zip(names, values):
                    if isinstance(n, ast.Name) and isinstance(v, ast.Constant) and isinstance(v.value, str):
                        consts[n.id] = v.value
    out: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) == "Outcome":
            first = node.args[0] if node.args else next((k.value for k in node.keywords if k.arg == "outcome"), None)
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                out.add(first.value)
            elif isinstance(first, ast.Name) and first.id in consts:
                out.add(consts[first.id])
            else:
                raise AssertionError(f"gate.py line {node.lineno}: the outcome of this Outcome(...) is not a "
                                     "string constant of the module; the vocabulary cannot be read")
    return frozenset(out)


def written_literals(source: str) -> frozenset[str]:
    """Outcome words a writer passes to `store.outcome(...)` as a literal (the account-hold supersede row)."""
    out: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "outcome":
            out |= {k.value.value for k in node.keywords
                    if k.arg == "outcome" and isinstance(k.value, ast.Constant) and isinstance(k.value.value, str)}
    return frozenset(out)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def reader_files() -> list[str]:
    found = []
    for top in ("scripts", "plugins"):
        for path in sorted((ROOT / top).rglob("*.py")):
            rel = path.relative_to(ROOT).as_posix()
            if "/tests/" in f"/{rel}" or "node_modules" in rel:
                continue
            if "dv_outcomes" in path.read_text(encoding="utf-8", errors="replace"):
                found.append(rel)
    return found


class EmitterVocabularyTests(unittest.TestCase):
    def test_the_gate_emits_exactly_the_pinned_words(self):
        self.assertEqual(emitted(read(GATE)), EMITTED,
                         "doc-verify's outcome words changed. Every file in READERS reads them as literals: "
                         "update EMITTED only together with each reader's row and each MAPS position.")

    def test_the_gates_constants_are_the_pinned_words(self):
        self.assertEqual({gate.FORGED, gate.FORGED_POSITIVE, gate.CONTRADICTED, gate.VERIFIED, gate.UNVERIFIABLE,
                          gate.UNKNOWN}, set(EMITTED))

    def test_no_other_writer_records_a_word_the_gate_does_not_emit(self):
        for rel in WRITERS:
            self.assertLessEqual(written_literals(read(rel)), EMITTED, rel)
        self.assertEqual(written_literals(read(WRITERS[0])), {"unverifiable"})       # the account-hold supersede

    def test_a_word_added_to_the_gate_fails_the_pin(self):
        grown = read(GATE) + '\n\ndef _later_edit():\n    return Outcome("partial", "", None, False, {})\n'
        self.assertEqual(emitted(grown) - EMITTED, {"partial"})
        self.assertNotEqual(emitted(grown), EMITTED)

    def test_a_word_renamed_in_the_gate_fails_the_pin(self):
        src = read(GATE)
        self.assertIn('"unverifiable"', src)
        renamed = emitted(src.replace('"unverifiable"', '"unreadable"'))
        self.assertNotIn("unverifiable", renamed)
        self.assertNotEqual(renamed, EMITTED)

    def test_an_outcome_that_cannot_be_read_from_the_source_is_refused(self):
        with self.assertRaises(AssertionError):
            emitted(read(GATE) + "\n\ndef _later_edit(word):\n    return Outcome(word.lower(), '', None, False, {})\n")


class ReaderVocabularyTests(unittest.TestCase):
    def test_every_file_that_reads_dv_outcomes_is_pinned(self):
        self.assertEqual(reader_files(), sorted(READERS),
                         "a file that reads dv_outcomes has no row in READERS (or a row names a file that no "
                         "longer reads it): add it with the outcome words it names")

    def test_each_reader_names_exactly_its_pinned_words(self):
        for rel, want in READERS.items():
            with self.subTest(reader=rel):
                self.assertEqual(named(read(rel)), want,
                                 f"{rel} now names different doc-verify outcome words. If that is intended, "
                                 "update its row; if not, a reader and the gate have just come apart.")

    def test_no_reader_is_pinned_to_a_word_the_gate_does_not_emit(self):
        for rel, want in READERS.items():
            self.assertLessEqual(want, EMITTED, rel)

    def test_every_emitted_word_is_named_by_a_reader_outside_doc_verify(self):
        outside = [w for rel, w in READERS.items() if "/docverify/" not in rel and rel != "scripts/credit-doc-verify.py"]
        self.assertEqual(frozenset().union(*outside), EMITTED)

    def test_each_translating_reader_takes_a_position_on_every_emitted_word(self):
        for rel, defaults in MAPS.items():
            with self.subTest(reader=rel):
                names = READERS[rel]
                self.assertFalse(names & set(defaults), "a word is both named and left to the default")
                self.assertEqual(names | set(defaults), EMITTED,
                                 f"{rel} translates outcomes and has no position on some emitted word")
                self.assertTrue(all(why.strip() for why in defaults.values()))

    def test_the_declared_maps_are_what_the_rows_say(self):
        from credit_review import doc_approve, proof_reviewer
        from ops_intake import proof_review, sources
        self.assertEqual(frozenset(sources.OUTCOME_WORDS), READERS["scripts/ops_intake/sources.py"])
        self.assertEqual(frozenset({proof_review.DV_VERIFIED, proof_review.DV_CONTRADICTED, proof_review.DV_FORGED,
                                    proof_review.DV_UNVERIFIABLE, proof_review.DV_UNKNOWN}),
                         READERS["scripts/ops_intake/proof_review.py"])
        self.assertLessEqual(set(proof_reviewer.DECISIVE), EMITTED)
        self.assertLessEqual(set(doc_approve.BLOCKING_VERDICTS), EMITTED)
        # the fallback the two unmapped words get in the Ops reply is the word itself, never another verdict
        for word in MAPS["scripts/ops_intake/sources.py"]:
            self.assertNotIn(word, sources.OUTCOME_WORDS)

    def test_a_word_added_to_a_reader_fails_its_row(self):
        rel = "scripts/credit_review/need_asks.py"
        self.assertNotIn("forged", READERS[rel])
        grown = named(read(rel) + '\n\ndef _later_edit(outcome):\n    return outcome == "forged"\n')
        self.assertEqual(grown - READERS[rel], {"forged"})
        ambiguous = named(read("scripts/credit_review/doc_close.py")
                          + "\n\ndef _later_edit(db):\n    return db.execute(\"SELECT 1 FROM dv_outcomes WHERE "
                          "outcome IN ('verified', 'unknown')\")\n")
        self.assertEqual(ambiguous - READERS["scripts/credit_review/doc_close.py"], {"verified", "unknown"})

    def test_a_word_a_reader_stops_naming_fails_its_row(self):
        rel = "scripts/ops_intake/sources.py"
        src = read(rel)
        self.assertIn('"unverifiable"', src)
        renamed = named(src.replace('"unverifiable"', '"unreadable"'))
        self.assertEqual(READERS[rel] - renamed, {"unverifiable"})

    def test_the_store_of_record_is_dv_outcomes_and_not_the_removal_executors_table(self):
        # doc-verify must never grow a write into proof_verifications: different table, different question,
        # different words (different | same | unreadable | pending)
        from credit_review import proof_verifications as pv
        self.assertFalse({pv.DIFFERENT, pv.SAME, pv.UNREADABLE, pv.PENDING} & EMITTED)
        for path in sorted((SCRIPTS / "credit_verify" / "docverify").glob("*.py")) + [SCRIPTS / "credit-doc-verify.py"]:
            self.assertNotIn("proof_verifications", path.read_text(encoding="utf-8"), path.name)


if __name__ == "__main__":
    unittest.main(verbosity=1)
