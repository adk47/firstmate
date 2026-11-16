"""The verification scale drain: rank order, idempotency, sharding, byte-identical re-run.

Design of record: data/verification-scale-plan.md. These tests pin the properties the
plan's Definition of done names, on hermetic fixtures:

  * a dry run over 1,000 real-shaped rows produces decisions, and running it twice
    produces byte-identical output (also across two separate PROCESSES, which is the
    version that actually catches a clock or a run id leaking into the plan);
  * the full 92,861-request decision pass is fast enough that the 90-minute budget is
    spent on the API, not on the ladder;
  * zero duplicate sends and zero orphans, including after a kill -9 mid-pass;
  * `expires_at` exists and a refusal names its reason code and is told once.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace as dataclasses_replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import need_asks as na  # noqa: E402
from credit_review import policy  # noqa: E402
from credit_review import scale_drain as sd  # noqa: E402

NOW = datetime(2026, 11, 11, 12, 0, 0, tzinfo=timezone.utc)
SCRIPTS = Path(__file__).resolve().parents[1]


REGISTRY = SCRIPTS.parent / "policies/credit-approval-automation.json"

#: The proof store's other table the snapshot reads: the documents customers filed. The
#: real store creates it beside ``verdicts`` (``credit_verify/proof/store.py``), and a
#: store without it is unreadable to the snapshot, so every fixture store carries it.
INTAKE_DDL = ("CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY,"
              " candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', received_at TEXT NOT NULL)")
#: No fixture reads the host's DSP store: a test that wants anchors passes its own file.
NO_DSP_STORE = "/nonexistent/dsp-verify.sqlite"
#: The snapshot joins the host's verify ledger when no path is given, and node-8's live
#: ledger is large enough to dominate a memory measurement. A test that wants ask history
#: passes its own ledger.
NO_LEDGER = "/nonexistent/verify-ledger.sqlite3"


def setUpModule():
    from credit_review import verify_ledger  # noqa: PLC0415
    from credit_verify.dspverify import store as dsp_store  # noqa: PLC0415

    for module, default in ((dsp_store, NO_DSP_STORE), (verify_ledger, NO_LEDGER)):
        pin = mock.patch.object(module, "DEFAULT_PATH", default)
        pin.start()
        unittest.addModuleCleanup(pin.stop)



def cli(*argv: str) -> list[str]:
    """The ONE CLI: the module's own entry point (f6 - two CLIs is how a bypass hides)."""
    return [sys.executable, "-m", "credit_review.scale_drain", *argv]


def rid(n: int) -> str:
    return f"{n:08x}-0000-4000-8000-000000000000"


def row(n: int, **kw) -> dict:
    base = {"request_id": rid(n), "profile_id": f"p{n}", "user_id": 1000 + n,
            "status": "user_verification_needed", "created_at": "2026-11-01T00:00:00Z"}
    base.update(kw)
    return base


def snapshot(rows, decided=(), precedent=()):
    db = sd.open_snapshot()
    sd.load_snapshot(db, rows)
    if decided:
        sd.load_decided(db, decided)
    if precedent:
        sd.load_precedent(db, precedent)
    return db


class DecisionKeyTests(unittest.TestCase):
    def test_key_is_sha256_of_request_rule_outcome_version(self):
        want = hashlib.sha256(
            f"{rid(1)}\x00precedent\x00approve\x00{sd.RULE_VERSION}".encode()).hexdigest()
        self.assertEqual(sd.decision_key(rid(1), "precedent", "approve"), want)

    def test_a_changed_outcome_is_a_new_key(self):
        """QA review 2: a decision that later becomes an approval must not be skipped."""
        self.assertNotEqual(sd.decision_key(rid(1), "proof_verdict", "ask"),
                            sd.decision_key(rid(1), "proof_verdict", "approve"))

    def test_key_differs_by_rule_and_version(self):
        a = sd.decision_key(rid(1), "precedent", "approve")
        b = sd.decision_key(rid(1), "ask", "ask")
        c = sd.decision_key(rid(1), "precedent", "approve", version="r2")
        self.assertEqual(len({a, b, c}), 3)

    def test_key_is_stable(self):
        self.assertEqual(sd.decision_key(rid(7), "expired", "cannot_confirm"),
                         sd.decision_key(rid(7), "expired", "cannot_confirm"))

    def test_unknown_rule_refused(self):
        with self.assertRaises(sd.DrainError):
            sd.decision_key(rid(1), "made_up", "ask")

    def test_empty_request_id_refused(self):
        with self.assertRaises(sd.DrainError):
            sd.decision_key("", "ask", "ask")


class RankOrderTests(unittest.TestCase):
    """Stop at the first match. The order IS the specification."""

    def test_a_request_naming_a_decided_original_is_decided_by_the_rules_below(self):
        """There is no duplicate close. A request that names a decided original is not
        matched by rule 1 at all: its own precedent decides it, and the plan row carries
        no original for a writer to act on."""
        db = snapshot(
            [row(1, duplicate_of=rid(99), precedent_key="k", proof_verdict="approve",
                 expires_at="2020-01-01T00:00:00Z")],
            decided=[{"request_id": rid(99), "decision": "approved"}],
            precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("precedent", "approve", "precedent_match"))
        self.assertEqual(d.evidence_anchor, rid(9))
        self.assertIsNone(d.duplicate_of)
        self.assertIsNone(d.as_row()["duplicate_of"])

    def test_duplicate_of_an_undecided_request_is_unmatched_not_asked(self):
        db = snapshot([row(1, duplicate_of=rid(99))])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "duplicate")
        self.assertEqual(d.outcome, sd.UNMATCHED)
        self.assertEqual(d.reason_code, "unmatched_duplicate")

    def test_precedent_beats_proof_and_expiry(self):
        db = snapshot([row(1, precedent_key="k", proof_verdict="refuse", asked_at="2020-01-01T00:00:00Z",
                            expires_at="2020-01-01T00:00:00Z")],
                      precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "precedent")
        self.assertEqual(d.outcome, "approve")
        self.assertEqual(d.reason_code, "precedent_match")

    def test_proof_verdict_beats_expiry(self):
        db = snapshot([row(1, proof_verdict="approve", proof_id="proof-1",
                            asked_at="2020-01-01T00:00:00Z", expires_at="2020-01-01T00:00:00Z")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "proof_verdict")
        self.assertEqual(d.outcome, "approve")
        self.assertEqual(d.reason_code, "proof_verdict_approve")
        self.assertEqual(d.evidence_anchor, "proof-1")

    def test_a_proof_approve_with_no_proof_id_is_unmatched(self):
        """The approve gate needs a row-specific anchor; a verdict with no proof id
        cannot produce one, so the row is surfaced rather than asked or approved."""
        db = snapshot([row(1, proof_verdict="approve")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.outcome, sd.UNMATCHED)
        self.assertEqual(d.reason_code, "unmatched_proof_verdict")

    def test_proof_verdict_refuse_is_an_ask_until_the_refusal_guard_exists(self):
        """No outcome is a person, and nothing yet tells "the document contradicts the
        claim" from "the document is not enough": the row is asked, and its reason code
        keeps the refusing verdict so the row can be found and planned again."""
        db = snapshot([row(1, proof_verdict="refuse")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.outcome, "ask")
        self.assertEqual(d.reason_code, "proof_verdict_refuse")

    def test_an_unmapped_verdict_is_unmatched_not_asked(self):
        db = snapshot([row(1, proof_verdict="maybe")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "proof_verdict")
        self.assertEqual(d.outcome, sd.UNMATCHED)
        self.assertEqual(d.reason_code, "unmatched_proof_verdict")

    def test_expired_beats_ask(self):
        db = snapshot([row(1, expires_at="2026-11-01T00:00:00Z", asked_at="2026-10-01T00:00:00Z")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "expired")
        self.assertEqual(d.outcome, "cannot_confirm")
        self.assertEqual(d.reason_code, "expired_no_proof")

    def test_expired_does_not_fire_when_proof_arrived(self):
        db = snapshot([row(1, expires_at="2026-11-01T00:00:00Z", asked_at="2026-10-01T00:00:00Z",
                            proof_received_at="2026-10-30T00:00:00Z")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "ask")
        # ...and the row says WHY it is not a first ask: a document is already on file
        self.assertEqual((d.outcome, d.reason_code), ("ask", "proof_on_file_undecided"))

    def test_an_ask_with_nothing_on_file_keeps_its_own_reason(self):
        d = sd.plan(snapshot([row(1)]), now=NOW)[0]
        self.assertEqual((d.rule, d.outcome, d.reason_code), ("ask", "ask", "no_rule_matched"))

    def test_expired_does_not_fire_before_the_window(self):
        # asked 2026-10-20, so the 30-day window closes 2026-11-19 - still open on NOW
        db = snapshot([row(1, expires_at="2026-12-01T00:00:00Z", asked_at="2026-10-20T00:00:00Z")])
        self.assertEqual(sd.plan(db, now=NOW)[0].rule, "ask")

    def test_the_window_runs_from_the_ask_not_from_creation(self):
        """QA review 3: a request created in January and asked yesterday must not expire
        today - one day after the customer was asked for documents is not a window."""
        db = snapshot([row(1, created_at="2026-01-01T00:00:00Z",
                           expires_at="2026-01-31T00:00:00Z",
                           asked_at="2026-11-10T00:00:00Z")])
        self.assertEqual(sd.plan(db, now=NOW)[0].rule, "ask")

    def test_an_ask_older_than_the_window_expires(self):
        db = snapshot([row(1, created_at="2026-01-01T00:00:00Z",
                           asked_at="2026-09-01T00:00:00Z")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual((d.rule, d.outcome), ("expired", "cannot_confirm"))

    def test_ask_is_the_fallthrough(self):
        db = snapshot([row(1)])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "ask")
        self.assertEqual(d.outcome, "ask")
        self.assertEqual(d.reason_code, "no_rule_matched")

    def test_only_pending_statuses_are_in_the_population(self):
        db = snapshot([row(1, status="approved"), row(2, status="rejected"),
                       row(3, status="unverified"), row(4, status="user_verification_needed")])
        self.assertEqual([d.request_id for d in sd.plan(db, now=NOW)], [rid(3), rid(4)])


class ExpiresAtTests(unittest.TestCase):
    def test_derived_from_created_at(self):
        self.assertEqual(sd.derive_expires_at("2026-11-01T00:00:00Z", 30),
                         "2026-12-01T00:00:00Z")

    def test_absent_created_at_yields_none(self):
        self.assertIsNone(sd.derive_expires_at(None))
        self.assertIsNone(sd.derive_expires_at("not-a-date"))

    def test_snapshot_populates_expires_at_when_core_carries_none(self):
        db = snapshot([row(1, created_at="2026-11-01T00:00:00Z")])
        got = db.execute("SELECT expires_at FROM requests WHERE request_id=?", (rid(1),)).fetchone()[0]
        self.assertEqual(got, "2026-12-01T00:00:00Z")

    def test_snapshot_keeps_a_core_supplied_expires_at(self):
        db = snapshot([row(1, expires_at="2027-01-01T00:00:00Z")])
        got = db.execute("SELECT expires_at FROM requests WHERE request_id=?", (rid(1),)).fetchone()[0]
        self.assertEqual(got, "2027-01-01T00:00:00Z")


class ShardTests(unittest.TestCase):
    def test_bounds_are_contiguous_and_cover_everything(self):
        ids = [rid(i) for i in range(100)]
        bounds = sd.shard_bounds(ids, 16)
        self.assertEqual(len(bounds), 16)
        self.assertEqual(bounds[0][0], 0)
        self.assertEqual(bounds[-1][1], 100)
        for (s1, e1), (s2, _e2) in zip(bounds, bounds[1:]):
            self.assertEqual(e1, s2)
        self.assertEqual(sum(e - s for s, e in bounds), 100)

    def test_bounds_are_deterministic_regardless_of_input_order(self):
        ids = [rid(i) for i in range(50)]
        self.assertEqual(sd.shard_bounds(ids, 8), sd.shard_bounds(list(reversed(ids)), 8))

    def test_shard_of_is_total_and_matches_bounds(self):
        ids = [rid(i) for i in range(37)]
        for i, r in enumerate(sorted(ids)):
            k = sd.shard_of(ids, 8, r)
            s, e = sd.shard_bounds(ids, 8)[k]
            self.assertTrue(s <= i < e)

    def test_shard_of_unknown_id_refused(self):
        with self.assertRaises(sd.DrainError):
            sd.shard_of([rid(1)], 4, rid(2))

    def test_more_shards_than_ids_is_safe(self):
        bounds = sd.shard_bounds([rid(1), rid(2)], 16)
        self.assertEqual(sum(e - s for s, e in bounds), 2)


class ByteIdenticalTests(unittest.TestCase):
    """The Definition of done: a dry run over 1,000 rows, twice, byte-identical."""

    def _thousand(self):
        rows = []
        for i in range(1000):
            kw = {}
            if i % 7 == 0:
                kw["duplicate_of"] = rid(9000 + i)
            elif i % 5 == 0:
                kw["precedent_key"] = f"k{i % 11}"
            elif i % 3 == 0:
                kw["proof_verdict"] = "approve" if i % 2 else "refuse"
            elif i % 11 == 0:
                kw["expires_at"] = "2026-10-01T00:00:00Z"
                kw["asked_at"] = "2026-09-01T00:00:00Z"
            rows.append(row(i, **kw))
        decided = [{"request_id": rid(9000 + i), "decision": "approved"} for i in range(0, 1000, 7)]
        precedent = [{"precedent_key": f"k{k}", "outcome": "approve"} for k in range(11)]
        return rows, decided, precedent

    def test_two_runs_are_byte_identical(self):
        rows, decided, precedent = self._thousand()
        a = sd.serialize(sd.plan(snapshot(rows, decided, precedent), now=NOW))
        b = sd.serialize(sd.plan(snapshot(rows, decided, precedent), now=NOW))
        self.assertEqual(a, b)
        self.assertEqual(len(a.splitlines()), 1000)

    def test_two_processes_are_byte_identical(self):
        """The version that catches a clock or a run id leaking into the plan."""
        rows, decided, precedent = self._thousand()
        with tempfile.TemporaryDirectory() as td:
            snap = Path(td) / "snap.jsonl"
            dec = Path(td) / "decided.jsonl"
            prec = Path(td) / "precedent.jsonl"
            snap.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            dec.write_text("\n".join(json.dumps(r) for r in decided) + "\n")
            prec.write_text("\n".join(json.dumps(r) for r in precedent) + "\n")
            outs = []
            for n in range(2):
                out = Path(td) / f"plan{n}.jsonl"
                subprocess.run(cli("plan", "--snapshot", str(snap),
                                "--decided", str(dec), "--precedent", str(prec),
                                "--out", str(out), "--now", "2026-11-11T12:00:00Z"),
                               check=True, capture_output=True, cwd=SCRIPTS)
                outs.append(out.read_bytes())
            self.assertEqual(outs[0], outs[1])
            self.assertEqual(len(outs[0].splitlines()), 1000)

    def test_plan_carries_no_clock_and_no_run_id(self):
        d = sd.plan(snapshot([row(1)]), now=NOW)[0]
        blob = json.dumps(d.as_row(), sort_keys=True)
        self.assertNotIn("2026-11-11", blob)
        self.assertNotIn("run_id", blob)
        self.assertNotIn("decided_at", blob)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.ledger = str(Path(self.td.name) / "ledger.sqlite")
        self.decisions = sd.plan(snapshot([row(i) for i in range(50)]), now=NOW)

    def tearDown(self):
        self.td.cleanup()

    def test_apply_is_idempotent(self):
        db = sd.open_ledger(self.ledger)
        first = sd.apply(self.decisions, db, shards=4, write_pool=2, now=NOW)
        second = sd.apply(self.decisions, db, shards=4, write_pool=2, now=NOW)
        self.assertEqual(first["applied"], 50)
        self.assertEqual(second["applied"], 0)
        self.assertEqual(second["skipped"], 50)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 50)

    def test_verify_is_clean_after_a_full_apply(self):
        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions, db, shards=4, write_pool=2, now=NOW)
        result = sd.verify(self.decisions, db)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["duplicate_request_ids"], [])

    def test_verify_reports_missing_and_orphans(self):
        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions[:10], db, shards=4, write_pool=2, now=NOW)
        result = sd.verify(self.decisions, db)
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["missing"]), 40)
        self.assertEqual(result["orphans"], [])

    def test_ledger_is_append_only(self):
        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions[:1], db, shards=1, write_pool=1, now=NOW)
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("UPDATE applied SET outcome='approve'")
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("DELETE FROM applied")

class ChaosTests(unittest.TestCase):
    """kill -9 every worker mid-pass, restart, verify zero duplicates and zero orphans."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.ledger = str(Path(self.td.name) / "ledger.sqlite")
        self.decisions = sd.plan(snapshot([row(i) for i in range(200)]), now=NOW)

    def tearDown(self):
        self.td.cleanup()

    def test_two_kills_produce_identical_final_state(self):
        db = sd.open_ledger(self.ledger)
        for _ in range(2):
            sd.apply(self.decisions, db, shards=8, write_pool=4, now=NOW, stop_after=37)
            result = sd.verify(self.decisions, db)
            self.assertEqual(result["duplicate_request_ids"], [])
            self.assertEqual(result["orphans"], [])
        final = sd.apply(self.decisions, db, shards=8, write_pool=4, now=NOW)
        self.assertEqual(final["applied"], 200 - 74)
        result = sd.verify(self.decisions, db)
        self.assertTrue(result["ok"], result)

    def test_a_kill_never_leaves_a_partial_row(self):
        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions, db, shards=8, write_pool=4, now=NOW, stop_after=13)
        rows = db.execute("SELECT decision_key, request_id, rule, outcome, reason_code FROM applied").fetchall()
        self.assertEqual(len(rows), 13)
        for key, request_id, rule, outcome, reason_code in rows:
            self.assertEqual(key, sd.decision_key(request_id, rule, outcome))
            self.assertTrue(outcome)
            self.assertTrue(reason_code)

    def test_chaos_cli_reports_ok(self):
        with tempfile.TemporaryDirectory() as td:
            plan = Path(td) / "plan.jsonl"
            plan.write_bytes(sd.serialize(self.decisions))
            ledger = str(Path(td) / "ledger.sqlite")
            proc = subprocess.run(cli("chaos", "--plan", str(plan),
                                   "--kill-after", "40", "--rounds", "2",
                                   "--shards", "8"), capture_output=True, text=True,
                                  cwd=SCRIPTS)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            out = json.loads(proc.stdout)
            self.assertTrue(out["ok"])
            # chaos makes its OWN ledger, in its own temp dir, and says where
            self.assertNotEqual(out["ledger"], ledger)
            self.assertIn("scale-drain-chaos-", out["ledger"])

    def test_chaos_never_takes_a_ledger_at_all(self):
        """A rehearsal must never poison a real ledger (QA review 3 of hydra#1883).

        Chaos commits writing outcomes with NO writer, so pointing it at a real ledger
        would mark approve/close rows applied without any API call and the next real apply
        would skip them. Refusing a NAMED ledger is not enough: an empty one is just as
        dangerous, and a fresh custom path a real run is about to use is indistinguishable
        from a scratch file. So chaos takes no ledger and makes its own.
        """
        with tempfile.TemporaryDirectory() as td:
            plan = Path(td) / "plan.jsonl"
            plan.write_bytes(sd.serialize(self.decisions))
            ledger = str(Path(td) / "ledger.sqlite")
            # a real apply already ran here
            db = sd.open_ledger(ledger)
            sd.apply(self.decisions, db, shards=8, write_pool=4, now=NOW, stop_after=5)
            before = db.execute("SELECT COUNT(*) FROM applied").fetchone()[0]
            self.assertEqual(before, 5)
            proc = subprocess.run(cli("chaos", "--plan", str(plan), "--ledger", ledger,
                                      "--kill-after", "40", "--rounds", "2", "--shards", "8"),
                                  capture_output=True, text=True, cwd=SCRIPTS)
            # the flag is gone, so argparse refuses it outright
            self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
            self.assertIn("unrecognized arguments", proc.stderr)
            # and the real ledger is untouched
            self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], before)


class ToldOnceTests(unittest.TestCase):
    def test_a_refusal_is_told_once(self):
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            self.assertTrue(sd.mark_told(db, rid(1), "expired_no_proof", NOW))
            self.assertFalse(sd.mark_told(db, rid(1), "expired_no_proof", NOW))
            # a different reason code is a different telling
            self.assertTrue(sd.mark_told(db, rid(1), "proof_verdict_refuse", NOW))

    def test_apply_records_a_row_it_cannot_confirm_and_marks_nobody_told(self):
        """What apply does today for a row that ends without an approval: one ledger row,
        no API write, no message, and no ``told`` mark. The mark this replaced was written
        for rows no message was ever sent to, so it said "told" about customers who were
        not. This pins the gap as it stands; it is not the behaviour to keep."""
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            decisions = sd.plan(snapshot([row(1, expires_at="2026-10-01T00:00:00Z", asked_at="2026-09-01T00:00:00Z"),
                                          row(2, proof_verdict="refuse")]), now=NOW)
            calls = []
            stats = sd.apply(decisions, db, shards=2, write_pool=1, writer=calls.append, now=NOW)
            self.assertEqual((stats["applied"], stats["told"], calls), (2, 0, []))
            again = sd.apply(decisions, db, shards=2, write_pool=1, writer=calls.append, now=NOW)
            self.assertEqual((again["applied"], again["skipped"], again["told"], calls), (0, 2, 0, []))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM told").fetchone()[0], 0)
            self.assertEqual(
                db.execute("SELECT request_id, outcome, reason_code FROM applied"
                           " ORDER BY request_id").fetchall(),
                [(rid(1), "cannot_confirm", "expired_no_proof"),
                 (rid(2), "ask", "proof_verdict_refuse")])

    def test_the_tier2_queue_lists_no_row(self):
        """No outcome is a person, so the list a person read is empty whatever the ledger
        holds: a row the ladder cannot confirm, a refused document, and a row recorded as
        ``queue_tier2`` by an earlier version of the ladder."""
        with tempfile.TemporaryDirectory() as td:
            ledger = str(Path(td) / "l.sqlite")
            db = sd.open_ledger(ledger)
            decisions = sd.plan(snapshot([
                row(1, expires_at="2026-10-01T00:00:00Z", asked_at="2026-09-01T00:00:00Z"),
                row(2, proof_verdict="refuse"),
                row(3),
            ]), now=NOW)
            sd.apply(decisions, db, shards=2, write_pool=1, now=NOW)
            db.execute("INSERT INTO applied (decision_key, request_id, rule, outcome,"
                       " reason_code, shard, applied_at) VALUES (?,?,?,?,?,?,?)",
                       ("k" * 64, rid(4), "precedent", "queue_tier2", "precedent_refuse", 0,
                        "2026-11-11T18:41:01Z"))
            db.commit()
            self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 4)
            out = Path(td) / "queue.jsonl"
            proc = subprocess.run(cli("tier2-queue", "--ledger", ledger, "--out", str(out)),
                                  cwd=SCRIPTS, capture_output=True, text=True, check=False)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(), "")
            self.assertIn('"queued": 0', proc.stderr)


class ScaleTests(unittest.TestCase):
    """The plan's arithmetic: 92,861 requests, 1,000/min, 93 minutes, < 90 min budget."""

    def test_full_pass_decision_cost_is_negligible(self):
        n = 92861
        rows = []
        for i in range(n):
            kw = {}
            if i % 14 == 0:
                kw["duplicate_of"] = rid(200000 + i)
            elif i % 10 == 0:
                kw["precedent_key"] = f"k{i % 50}"
            elif i % 6 == 0:
                kw["proof_verdict"] = "approve"
            elif i % 23 == 0:
                kw["expires_at"] = "2026-10-01T00:00:00Z"
                kw["asked_at"] = "2026-09-01T00:00:00Z"
            rows.append(row(i, **kw))
        decided = [{"request_id": rid(200000 + i), "decision": "approved"} for i in range(0, n, 14)]
        precedent = [{"precedent_key": f"k{k}", "outcome": "approve"} for k in range(50)]
        db = snapshot(rows, decided, precedent)
        t0 = time.perf_counter()
        decisions = sd.plan(db, now=NOW)
        elapsed = time.perf_counter() - t0
        self.assertEqual(len(decisions), n)
        # The ladder is microseconds per row; the 90-minute budget belongs to the API.
        self.assertLess(elapsed, 60.0, f"the decision pass took {elapsed:.1f}s for {n} rows")
        self.assertLess(elapsed * 1000.0 / n, 100.0, "per-request decision cost must be < 100 ms")

    def test_the_plan_arithmetic_holds(self):
        # 92,861 at 1,000/min is 93 minutes; the budget is 90, so the pass must run
        # slightly above 1,000/min. This is the checkable form of the plan's target.
        self.assertLess(92861 / 1000.0, 90.0 + 3.0)


class UnaskedIsAskedTests(unittest.TestCase):
    """Firstmate decision: ask comes before expiry for a request that was never asked.

    The 23,247 OPEN_UNASKED rows are the drain's population, not its expiry pile: an
    expiry is the record of a window the customer was given and did not answer.
    """

    def test_an_unasked_request_past_its_window_is_asked_not_expired(self):
        db = snapshot([row(1, expires_at="2026-10-01T00:00:00Z")])  # asked_at is NULL
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "ask")
        self.assertEqual(d.outcome, "ask")
        self.assertEqual(d.reason_code, "no_rule_matched")

    def test_an_asked_request_past_its_window_is_expired(self):
        db = snapshot([row(1, expires_at="2026-10-01T00:00:00Z", asked_at="2026-09-01T00:00:00Z")])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "expired")
        self.assertEqual(d.outcome, "cannot_confirm")
        self.assertEqual(d.reason_code, "expired_no_proof")

    def test_an_unasked_request_inside_its_window_is_asked(self):
        db = snapshot([row(1, expires_at="2026-12-01T00:00:00Z")])
        self.assertEqual(sd.plan(db, now=NOW)[0].rule, "ask")

    def test_an_unasked_request_with_proof_still_uses_the_verdict(self):
        db = snapshot([row(1, proof_verdict="approve", expires_at="2026-10-01T00:00:00Z")])
        self.assertEqual(sd.plan(db, now=NOW)[0].rule, "proof_verdict")

    def test_asked_at_survives_the_snapshot_round_trip(self):
        db = snapshot([row(1, asked_at="2026-09-01T00:00:00Z")])
        got = db.execute("SELECT asked_at FROM requests WHERE request_id=?", (rid(1),)).fetchone()[0]
        self.assertEqual(got, "2026-09-01T00:00:00Z")


class PrecedentOutcomeTests(unittest.TestCase):
    """A precedent carries its own outcome, and a refuse precedent is not a refusal:
    another claimant holding the credit is no evidence against this one."""

    def test_refuse_precedent_is_a_row_the_ladder_cannot_confirm(self):
        db = snapshot([row(1, precedent_key="k")],
                      precedent=[{"precedent_key": "k", "outcome": "refuse"}])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.rule, "precedent")
        self.assertEqual(d.outcome, "cannot_confirm")
        self.assertEqual(d.reason_code, "precedent_refuse")

    def test_approve_precedent_approves(self):
        db = snapshot([row(1, precedent_key="k")],
                      precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}])
        self.assertEqual(sd.plan(db, now=NOW)[0].outcome, "approve")

    def test_unreadable_precedent_outcome_is_unmatched_not_asked(self):
        db = snapshot([row(1, precedent_key="k")],
                      precedent=[{"precedent_key": "k", "outcome": "maybe"}])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual(d.outcome, sd.UNMATCHED)
        self.assertEqual(d.reason_code, "unmatched_precedent")


class HeldRowTests(unittest.TestCase):
    """A request on a hold core's guard does not act on is never an ``approve`` in the plan.

    2026-11-13: two requests carrying ``track_pending_capture`` at risk 100 were approved on
    precedent 17 minutes after the hold was set. The ladder read no hold code, and the
    guard holds only on a ``review_*`` rule at 30 or more, class C, or ``_hold_on_error``.
    A hold the guard does act on is not this stop's: that row stays ``approve``.
    """

    PRECEDENT = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]

    def _plan(self, **kw):
        return sd.plan(snapshot([row(1, precedent_key="k", **kw)],
                                precedent=self.PRECEDENT), now=NOW)[0]

    def test_a_held_request_with_an_approve_precedent_is_not_approved(self):
        d = self._plan(uncovered_holds=["track_pending_capture"])
        self.assertEqual(d.rule, "precedent")
        self.assertEqual(d.outcome, sd.UNMATCHED)
        self.assertEqual(d.reason_code, "held_by_validator")
        # ...and the same request without the hold is the approve this test is about
        self.assertEqual(self._plan().outcome, "approve")
        self.assertEqual(self._plan(uncovered_holds=[]).outcome, "approve")

    def test_every_uncovered_code_blocks_whatever_its_name(self):
        for code in ("track_pending_capture", "review_hourly_velocity_profile",
                     "score:track_credit", "a_code_nobody_has_written_yet",
                     sd_va().HOLD_UNREADABLE):
            with self.subTest(code=code):
                self.assertEqual(self._plan(uncovered_holds=[code]).outcome, sd.UNMATCHED)

    def test_a_hold_the_guard_covers_stays_an_approve_and_carries_its_cause(self):
        """Main's route, unchanged: the row goes to core, which refuses it."""
        d = self._plan(hold_causes=["review_big_track_without_trusted_credit"])
        self.assertEqual(d.outcome, "approve")
        self.assertEqual(d.hold_causes, ("review_big_track_without_trusted_credit",))

    def test_from_the_stored_verdict_to_the_plan(self):
        """The replica read, the load and the ladder together: the 2026-11-13 verdict is
        left out of the plan, and the same hold code beside a rule the guard holds on is
        planned as the approve core will refuse."""
        def pending(n, vd):
            return (rid(n), "1001", rid(7), "user_verification_needed", "2026-11-01T00:00:00Z",
                    json.dumps(vd), "{}", f"trk-{n}", "{Mastering}")
        uncovered = {"is_approved": False, "hold_reason_codes": ["track_pending_capture"],
                     "rule_risk_percent": {"track_pending_capture": 100},
                     "total_risk_percent": 100}
        covered = {"is_approved": False,
                   "hold_reason_codes": ["track_pending_capture",
                                         "review_big_track_without_trusted_credit"],
                   "rule_risk_percent": {"track_pending_capture": 100,
                                         "review_big_track_without_trusted_credit": 40}}
        rows = sd.snapshot_from_replica(
            lambda sql: [pending(1, uncovered), pending(2, covered)],
            ledger_path="/nonexistent/ledger.sqlite", proof_store_path="/nonexistent/proof.sqlite")
        for r in rows:
            r["precedent_key"] = "k"
        first, second = sd.plan(snapshot(rows, precedent=self.PRECEDENT), now=NOW)
        self.assertEqual((first.outcome, first.reason_code), (sd.UNMATCHED, "held_by_validator"))
        self.assertEqual(second.outcome, "approve")
        self.assertEqual(second.hold_causes, ("review_big_track_without_trusted_credit",))

    def test_a_held_request_with_an_approve_proof_verdict_is_not_approved(self):
        db = snapshot([row(1, proof_verdict="approve", proof_id="a" * 64,
                           uncovered_holds=["track_pending_capture"]),
                       row(2, proof_verdict="approve", proof_id="b" * 64)])
        held, free = sd.plan(db, now=NOW)
        self.assertEqual((held.outcome, held.reason_code), (sd.UNMATCHED, "held_by_validator"))
        self.assertEqual(free.outcome, "approve")

    def test_a_held_request_is_never_written(self):
        db = snapshot([row(1, precedent_key="k", uncovered_holds=["track_pending_capture"])],
                      precedent=self.PRECEDENT)
        decisions = sd.plan(db, now=NOW)
        self.assertEqual([d for d in decisions if d.outcome in sd.WRITING_OUTCOMES], [])

    def test_through_apply_it_is_counted_never_written_and_never_asked(self):
        """The whole path after the plan: ``apply`` calls no writer for the held row and
        counts it, the run still verifies, and neither ask source hands it on - not the
        ladder's ask rows, not the rows core refused onto the ask path."""
        from credit_review import need_asks  # noqa: PLC0415

        decisions = sd.plan(
            snapshot([row(1, precedent_key="k", uncovered_holds=["track_pending_capture"]),
                      row(2)], precedent=self.PRECEDENT), now=NOW)
        calls = []
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            stats = sd.apply(decisions, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            self.assertEqual(calls, [])
            self.assertEqual(stats["unmatched"], 1)
            self.assertEqual([r[0] for r in db.execute("SELECT request_id FROM applied")], [rid(2)])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 0)
            self.assertTrue(sd.verify(decisions, db)["ok"])
            plan_path = Path(td) / "plan.jsonl"
            plan_path.write_bytes(sd.serialize(decisions))
            self.assertEqual(need_asks.drain_asks(str(plan_path)), {(1002, rid(2))})
            self.assertEqual(sd.refused_asks(db), [])

    def test_the_hold_changes_only_an_approve(self):
        """A row that cannot be confirmed, a request naming a decided original and an ask
        are not approvals: unchanged."""
        held = {"uncovered_holds": ["track_pending_capture"]}
        db = snapshot(
            [row(1, precedent_key="no", **held), row(2, duplicate_of=rid(8), **held),
             row(3, **held)],
            decided=[{"request_id": rid(8), "decision": "approved"}],
            precedent=[{"precedent_key": "no", "outcome": "refuse"}])
        self.assertEqual([d.outcome for d in sd.plan(db, now=NOW)],
                         ["cannot_confirm", "ask", "ask"])

    def test_a_snapshot_made_before_the_column_gains_it(self):
        with tempfile.TemporaryDirectory() as td:
            path = str(Path(td) / "snap.sqlite")
            old = sqlite3.connect(path)
            old.executescript(sd.SNAPSHOT_SCHEMA.replace("  uncovered_holds   TEXT,\n", ""))
            self.assertNotIn("uncovered_holds",
                             {r[1] for r in old.execute("PRAGMA table_info(requests)")})
            old.close()
            db = sd.open_snapshot(path)
            sd.load_snapshot(db, [row(1, uncovered_holds=["track_pending_capture"])])
            self.assertEqual(db.execute("SELECT uncovered_holds FROM requests").fetchone()[0],
                             '["track_pending_capture"]')

    def test_the_replica_read_carries_the_uncovered_codes_and_an_unreadable_verdict_is_one(self):
        def pending(n, vd_json):
            return (f"r{n}", "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
                    vd_json, "{}", f"trk-{n}", "{Mastering}")
        rows = sd.snapshot_from_replica(
            lambda sql: [
                pending(1, '{"is_approved": false, "hold_reason_codes": ["track_pending_capture"],'
                           ' "total_risk_percent": 100}'),
                pending(2, '{"is_approved": true, "hold_reason_codes": []}'),
                pending(3, None),
                pending(4, "{not json"),
                pending(5, '{"hold_reason_codes": "track_pending_capture"}'),
                pending(6, '"a string"'),
                # The guard holds on this one (a review_* rule at 30): core's to refuse.
                pending(7, '{"hold_reason_codes": ["track_pending_capture"],'
                           ' "rule_risk_percent": {"review_role_cardinality": 30}}'),
                # A review_* code under the guard's 30 is not one the guard holds on.
                pending(8, '{"hold_reason_codes": ["review_role_cardinality"],'
                           ' "rule_risk_percent": {"review_role_cardinality": 29}}'),
            ],
            ledger_path="/nonexistent/ledger.sqlite", proof_store_path="/nonexistent/proof.sqlite")
        unreadable = [sd_va().HOLD_UNREADABLE]
        self.assertEqual([r["uncovered_holds"] for r in rows],
                         [["track_pending_capture"], [], [], unreadable, unreadable, unreadable,
                          [], ["review_role_cardinality"]])


def sd_va():
    from credit_review import verify_anchor  # noqa: PLC0415
    return verify_anchor


class ReviewedWritePathTests(unittest.TestCase):
    """Firstmate decision: apply performs a REAL API side effect through the reviewed path.

    The reviewed path is the one ``muso-admin-api.sh`` already exposes and the lobster MVP
    already uses: a chunked ``PUT /admin/credit-requests {"requestIds":[...],"status":...}``
    through the wrapper. These tests pin the verb, the body, the status mapping, the
    approve-gate evidence treatment, and the write-then-commit ordering.
    """

    def _writer(self, rc=0, stdout=None):
        calls = []
        # The approve reads the root-only token file. The path is pinned, so the scratch
        # file is handed over as an in-process argument: there is no environment variable
        # that selects it, and setting one is refused (see
        # test_a_caller_supplied_token_file_is_denied_for_an_approve).
        token = Path(tempfile.mkdtemp()) / "scale-drain.token"
        token.write_text("s3cret\n")

        class Proc:
            returncode = rc
            stderr = "" if rc == 0 else "boom"

        def run(argv, **kw):
            calls.append({"argv": argv, "env": kw.get("env") or {}})
            p = Proc()
            p.stdout = stdout if stdout is not None else json.dumps(
                {"http_status": 200, "body": json.dumps({"data": {"updatedIds": [rid(1)]}})})
            return p

        return sd.admin_writer("/opt/hydra/scripts/muso-admin-api.sh", runner=run,
                               token_file=str(token)), calls

    def _with_env(self, name: str, value: str) -> None:
        saved = os.environ.get(name)
        os.environ[name] = value
        self.addCleanup(lambda: os.environ.pop(name, None) if saved is None
                        else os.environ.__setitem__(name, saved))

    def test_the_token_path_is_pinned_and_is_not_read_from_the_environment(self):
        self.assertEqual(sd.DRAIN_TOKEN_FILE, "/etc/hydra/scale-drain.token")
        self.assertEqual(sd.admin_writer.__kwdefaults__["token_file"], sd.DRAIN_TOKEN_FILE)
        # the CLI offers no way to name another file
        source = Path(sd.__file__).read_text()
        self.assertNotIn("--token-file", source)
        self.assertNotIn('environ.get("SCALE_DRAIN_TOKEN_FILE"', source)

    # ── the approve presents the drain's identity (QA review 5) ─────────────
    def _approve(self):
        return sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                           sd.decision_key(rid(1), "precedent", "approve"),
                           evidence_anchor=rid(9), profile_id=rid(7))

    def test_an_approve_presents_the_pinned_token(self):
        """An approval is the more consequential write, and it used to present nothing
        but values the caller sets. It now carries what the pinned file holds - never a
        SCALE_DRAIN_TOKEN that was already in the environment."""
        w, calls = self._writer()
        self._with_env("SCALE_DRAIN_TOKEN", "attacker-chosen")
        w(self._approve())
        self.assertEqual(calls[0]["env"]["SCALE_DRAIN_TOKEN"], "s3cret")
        self.assertNotIn("SCALE_DRAIN_TOKEN_FILE", calls[0]["env"])

    def test_a_missing_token_file_refuses_the_approve(self):
        calls = []
        w = sd.admin_writer("/opt/hydra/scripts/muso-admin-api.sh",
                            runner=lambda *a, **k: calls.append(a),
                            token_file=str(Path(tempfile.mkdtemp()) / "absent.token"))
        with self.assertRaises(sd.DrainWriteError) as ctx:
            w(self._approve())
        self.assertIn("approve needs", str(ctx.exception))
        self.assertEqual(calls, [])

    def test_a_caller_supplied_token_file_is_denied_for_an_approve(self):
        for value in (str(Path(tempfile.mkdtemp()) / "mine.token"), "", sd.DRAIN_TOKEN_FILE):
            with self.subTest(value=value):
                w, calls = self._writer()
                os.environ["SCALE_DRAIN_TOKEN_FILE"] = value
                try:
                    with self.assertRaises(sd.DrainWriteError) as ctx:
                        w(self._approve())
                finally:
                    del os.environ["SCALE_DRAIN_TOKEN_FILE"]
                self.assertIn("cannot be redirected", str(ctx.exception))
                self.assertEqual(calls, [])

    def test_approve_puts_approved_through_the_wrapper(self):
        w, calls = self._writer()
        w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                      sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9)))
        self.assertEqual(len(calls), 1)
        argv = calls[0]["argv"]
        self.assertEqual(argv[0], "bash")
        self.assertEqual(argv[1], "/opt/hydra/scripts/muso-admin-api.sh")
        self.assertIn("call", argv)
        self.assertIn("PUT", argv)
        self.assertIn("/admin/credit-requests", argv)
        body = json.loads(argv[-1])
        self.assertEqual(body, {"requestIds": [rid(1)], "status": "approved"})
        self.assertEqual(calls[0]["env"]["OPS_DRY_RUN"], "0")

    def test_approve_carries_the_approve_gate_evidence(self):
        """The gate is SATISFIED, never disabled: no CV_APPROVE_GATE_DISABLED, and the
        digest names the auto-approvable rule plus the row-specific anchor."""
        w, calls = self._writer()
        w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                      sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9)))
        env = calls[0]["env"]
        self.assertNotIn("CV_APPROVE_GATE_DISABLED", env)
        self.assertEqual(env["SCALE_DRAIN"], "1")
        self.assertEqual(env["EVIDENCE_EXCERPT"],
                         f"drain-signal:precedent;precedent_match;v{sd.RULE_VERSION};{rid(9)};-")
        self.assertIn("--evidence-excerpt", calls[0]["argv"])

    def test_approve_signs_in_as_the_drains_own_account(self):
        """core binds verification-scale-drain to agent-scale-drain@ and to no other
        account, so the approve names that identity whatever the caller's env says."""
        w, calls = self._writer()
        with mock.patch.dict(os.environ, {"MUSO_ADMIN_IDENTITY": "credit-decider"}):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve"),
                          evidence_anchor=rid(9)))
        self.assertEqual(sd.ADMIN_IDENTITY, "scale-drain")
        self.assertEqual(calls[0]["env"]["MUSO_ADMIN_IDENTITY"], "scale-drain")
    def test_an_approve_without_an_anchor_is_refused(self):
        """A row the ladder could not anchor is not auto-approvable - never approve blind."""
        w, calls = self._writer()
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve")))
        self.assertEqual(calls, [])

    def test_a_non_auto_approvable_rule_is_refused(self):
        w, calls = self._writer()
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "ask", "approve", "no_rule_matched",
                          sd.decision_key(rid(1), "ask", "ask"), evidence_anchor=rid(9)))
        self.assertEqual(calls, [])

    def test_a_row_that_cannot_be_confirmed_performs_no_write(self):
        """``cannot_confirm`` has no status in core: the writer sends nothing for it."""
        w, calls = self._writer()
        w(sd.Decision(rid(1), "expired", "cannot_confirm", "expired_no_proof",
                      sd.decision_key(rid(1), "expired", "cannot_confirm")))
        self.assertEqual(calls, [])

    def test_a_duplicate_close_decision_performs_no_write(self):
        """The outcome is retired: handed one anyway, the writer spawns nothing."""
        w, calls = self._writer()
        w(sd.Decision(rid(1), "duplicate", "close_duplicate", "duplicate_of_decided",
                      sd.decision_key(rid(1), "duplicate", "close_duplicate"), status="unverified",
                      duplicate_of=rid(9)))
        self.assertEqual(calls, [])

    def test_the_writer_writes_no_status_but_approved(self):
        """``rejected`` notifies the customer and reads back as a refusal of the claim. A
        mapping that brought it back - for any outcome - is refused before the wrapper is
        spawned, whatever the decision carries."""
        self.assertEqual(sd.WRITE_STATUS, {"approve": "approved"})
        for outcome, status in (("close_duplicate", "rejected"), ("cannot_confirm", "rejected"),
                                ("ask", "unverified")):
            with self.subTest(outcome=outcome, status=status):
                w, calls = self._writer()
                with mock.patch.dict(sd.WRITE_STATUS, {outcome: status}):
                    with self.assertRaises(sd.DrainWriteError) as ctx:
                        w(sd.Decision(rid(1), "precedent", outcome, "precedent_match",
                                      sd.decision_key(rid(1), "precedent", outcome),
                                      status="unverified", evidence_anchor=rid(9),
                                      duplicate_of=rid(9)))
                self.assertIn("writes only 'approved'", str(ctx.exception))
                self.assertEqual(ctx.exception.layer, sd.LAYER_LOCAL)
                self.assertEqual(calls, [])

    def test_ask_performs_no_write(self):
        w, calls = self._writer()
        w(sd.Decision(rid(1), "ask", "ask", "no_rule_matched", sd.decision_key(rid(1), "ask", "ask")))
        self.assertEqual(calls, [])

    def test_a_non_2xx_raises_and_is_not_committed(self):
        w, calls = self._writer(rc=0, stdout='{"http_status":500,"body":{}}')
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9)))
        self.assertEqual(len(calls), 1)

    def test_a_200_that_omits_the_row_is_a_failed_write(self):
        w, _ = self._writer(rc=0, stdout=json.dumps(
            {"http_status": 200, "body": json.dumps({"data": {"updatedIds": [rid(2)]}})}))
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9)))

    def test_a_200_with_no_per_row_report_is_unattributable(self):
        w, _ = self._writer(rc=0, stdout='{"http_status":200,"body":{"data":{"ok":true}}}')
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9)))

    def test_a_wrapper_failure_raises(self):
        w, _ = self._writer(rc=1)
        with self.assertRaises(sd.DrainWriteError):
            w(sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                          sd.decision_key(rid(1), "precedent", "approve")))

    def test_apply_calls_the_writer_only_for_writing_outcomes(self):
        """An ask belongs to need_asks.py, and a refused document is an ask: no write."""
        decisions = sd.plan(snapshot([row(1, precedent_key="k"), row(2), row(3, proof_verdict="refuse")],
                                     precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]),
                            now=NOW)
        seen = []
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            stats = sd.apply(decisions, db, shards=2, write_pool=1, writer=seen.append, now=NOW)
        self.assertEqual(stats["applied"], 3)
        self.assertEqual([d.request_id for d in seen], [rid(1)])

    def test_a_failed_write_is_not_committed_and_is_retried(self):
        """A failure leaves the row unapplied and its intent open. The next run retries
        it - once the live request has been read and found still pending, never blind."""
        decisions = sd.plan(snapshot([row(1, precedent_key="k")],
                                     precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]), now=NOW)
        attempts = []

        def flaky(d):
            attempts.append(d.request_id)
            if len(attempts) == 1:
                raise sd.DrainWriteError("transient")

        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            first = sd.apply(decisions, db, shards=1, write_pool=1, writer=flaky, now=NOW)
            self.assertEqual(first["applied"], 0)
            self.assertEqual(first["errors"], 1)
            self.assertEqual(sd.verify(decisions, db)["missing"], [decisions[0].decision_key])
            self.assertEqual(sd.verify(decisions, db)["unconfirmed"], [rid(1)])
            # no reconciler: the failure did not prove the write missed, so no second call
            blind = sd.apply(decisions, db, shards=1, write_pool=1, writer=flaky, now=NOW)
            self.assertEqual((blind["applied"], blind["unreconciled"]), (0, 1))
            self.assertEqual(len(attempts), 1)
            second = sd.apply(decisions, db, shards=1, write_pool=1, writer=flaky, now=NOW,
                              reconciler=lambda d, planned_at: sd.NOT_LANDED)
            self.assertEqual(second["applied"], 1)
            self.assertEqual(len(attempts), 2)
            self.assertTrue(sd.verify(decisions, db)["ok"])



class ReplicaSnapshotTests(unittest.TestCase):
    """The bulk read comes from the replica, not the admin list.

    The admin list refuses unfiltered paging past offset 20,000, and 92,861 rows at
    limit=200 is page 465 - so the admin API cannot enumerate the population at all.
    """

    def _query(self, pending, decided=()):
        calls = []

        def q(sql):
            calls.append(sql)
            return list(decided) if "status IN ('approved', 'rejected')" in sql else list(pending)
        return q, calls

    def _proof_store(self, td, rows):
        path = str(Path(td) / "proof.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO verdicts (proof_id, request_id, verdict, created_at)"
                       " VALUES (?,?,?,?)", rows)
        db.commit()
        db.close()
        return path

    def _ledger(self, td):
        ledger = str(Path(td) / "ledger.sqlite")
        db = sqlite3.connect(ledger)
        db.executescript(
            "CREATE TABLE verify_messages (campaign TEXT, status TEXT, account_id TEXT,"
            " sent_at TEXT, request_ids_json TEXT NOT NULL);")
        db.execute("INSERT INTO verify_messages VALUES"
                   " ('verify-live','sent','1001','2026-09-01T00:00:00Z','[\"r1\"]')")
        db.execute("INSERT INTO verify_messages VALUES"
                   " ('removal-notice','sent','1002','2026-09-01T00:00:00Z','[\"r2\"]')")
        db.commit()
        db.close()
        return ledger

    def test_rows_are_mapped_and_asked_at_comes_from_the_ledger(self):
        with tempfile.TemporaryDirectory() as td:
            ledger = self._ledger(td)
            # keyed the way stage 2 writes it: one verdict per claimed role
            proofs = self._proof_store(
                td, [("a" * 64, "r1#Mixing Engineer", "GENUINE", "2026-11-02T00:00:00Z")])
            q, calls = self._query([
                ("r1", "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
                 '{"duplicate_of": null}', "{}", "trk-1", '{Mixing Engineer}'),
                ("r2", "1002", "p2", "unverified", "2026-11-01T00:00:00Z", "{}", "{}", "trk-1", '{Producer}'),
            ])
            rows = sd.snapshot_from_replica(q, ledger_path=ledger, proof_store_path=proofs)
        self.assertEqual(len(calls), 1, "one query for the whole population")
        self.assertEqual(rows[0]["asked_at"], "2026-09-01T00:00:00Z")
        self.assertEqual(rows[0]["claimed_roles"], ["Mixing Engineer"])
        self.assertEqual(rows[0]["precedent_key"], sd.claim_key("1001", "trk-1", ["Mixing Engineer"]))
        self.assertEqual(rows[0]["proof_verdict"], "approve")
        self.assertEqual(rows[0]["proof_id"], "a" * 64)
        self.assertEqual(rows[0]["proof_received_at"], "2026-11-02T00:00:00Z")
        self.assertIsNone(rows[1]["proof_verdict"])
        # a removal notice is NOT an ask
        self.assertIsNone(rows[1]["asked_at"])

    def test_the_snapshot_reads_why_the_validator_holds_each_request(self):
        """Core answers every validator hold with one word; the cause is read here, from
        the same stored verdict core reads, and an unreadable verdict is not measured."""
        def vd(**kw):
            return json.dumps(kw)
        pending = [
            ("r1", "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
             vd(rule_risk_percent={"review_big_track_without_trusted_credit": 100,
                                   "review_hourly_velocity_profile": 29,
                                   "review_hold_for_documents": 30, "track_credit": 70,
                                   "collaborations": 90, "reject_artist_credit": 100}),
             "{}", "t", "{Producer}"),
            ("r2", "1002", "p2", "user_verification_needed", "2026-11-01T00:00:00Z",
             vd(rule_risk_percent={"review_held_submitter": 100},
                fraud_hold={"decision": "hold"}, rule_errors={"_hold_on_error": "x"}),
             "{}", "t", "{Producer}"),
            ("r3", "1003", "p3", "user_verification_needed", "2026-11-01T00:00:00Z",
             vd(rule_risk_percent={"track_credit": 69, "collaborations": 90,
                                   "review_role_cardinality": True},
                fraud_hold={"decision": "clear"}),
             "{}", "t", "{Producer}"),
            ("r4", "1004", "p4", "user_verification_needed", "2026-11-01T00:00:00Z",
             "{}", "{}", "t", "{Producer}"),
            ("r5", "1005", "p5", "user_verification_needed", "2026-11-01T00:00:00Z",
             "not json", "{}", "t", "{Producer}"),
            ("r6", "1006", "p6", "user_verification_needed", "2026-11-01T00:00:00Z",
             vd(rule_risk_percent=[1, 2]), "{}", "t", "{Producer}"),
            # band C outside core's review_* reading: reject rules, the error keys, the
            # validator's own codes. A rule at zero did not fire; a reject rule the band
            # table does not list is not a cause here.
            ("r7", "1007", "p7", "user_verification_needed", "2026-11-01T00:00:00Z",
             vd(rule_risk_percent={"reject_publisher_label_credit": 100,
                                   "reject_deleted_catalog_track": 0,
                                   "validation_error": 100,
                                   "reject_a_rule_outside_the_table": 100},
                rule_errors={"_no_signal": "x", "something_else": "y"},
                hold_reason_codes=["reject_individual_org_credit",
                                   "risk_score_at_or_above_threshold"]),
             "{}", "t", "{Producer}"),
        ]
        with tempfile.TemporaryDirectory() as td:
            q, _calls = self._query(pending)
            rows = sd.snapshot_from_replica(q, ledger_path=self._ledger(td),
                                            proof_store_path=self._proof_store(td, []))
        self.assertEqual([r["hold_causes"] for r in rows], [
            ["class_c", "reject_artist_credit", "review_big_track_without_trusted_credit",
             "review_hold_for_documents"],
            ["_hold_on_error", "fraud_hold", "review_held_submitter"],
            [],         # under both class C thresholds; a boolean is not a score; cleared
            None,       # no verdict on the row: not measured, never "holds nothing"
            None,       # unreadable JSON
            None,       # rules that are not a map
            ["_no_signal", "reject_individual_org_credit", "reject_publisher_label_credit",
             "validation_error"],
        ])

    def test_every_band_c_cause_of_the_table_is_read_wherever_the_verdict_records_it(self):
        """Core's reading shows ``review_*`` at 30 or more and nothing else, so a
        ``reject_*`` rule and ``validation_error`` were invisible (review of #1976). The
        list is the band table's own, read at run time."""
        bands = json.loads((SCRIPTS / "credit_trust/credit_trust_bands.json").read_text())
        table = set(bands["band_c_rules"]) | set(bands["band_c_error_keys"])
        self.assertEqual(sd.band_c_causes(), table)
        self.assertGreaterEqual(len(bands["band_c_rules"]), 12)
        for cause in sorted(table):
            for where, verdict in (
                    ("rule", {"rule_risk_percent": {cause: 100}}),
                    ("error", {"rule_risk_percent": {}, "rule_errors": {cause: "x"}}),
                    ("code", {"rule_risk_percent": {}, "hold_reason_codes": [cause]})):
                with self.subTest(cause=cause, where=where):
                    self.assertIn(cause, sd.hold_causes(verdict))
            with self.subTest(cause=cause, where="did not fire"):
                self.assertEqual(sd.hold_causes({"rule_risk_percent": {cause: 0}}), [])
            # a review_ rule holds from 30 up, as in core's reading; any other band C
            # rule holds as soon as it fired
            with self.subTest(cause=cause, where="low score"):
                low = sd.hold_causes({"rule_risk_percent": {cause: 29}})
                self.assertEqual(low, [] if cause.startswith("review_") else [cause])

    def test_a_band_table_that_cannot_be_read_measures_nothing(self):
        verdict = {"rule_risk_percent": {"review_big_track_without_trusted_credit": 40}}
        kept = policy._BANDS
        try:
            for broken in ({}, {"band_c_rules": "x", "band_c_error_keys": []},
                           {"band_c_rules": [], "band_c_error_keys": []},
                           {"band_c_rules": ["reject_artist_credit"]},
                           # an entry that is not a rule name: dropping it would leave a
                           # shorter list that reads as complete (QA review of #1979)
                           {"band_c_rules": [None], "band_c_error_keys": []},
                           {"band_c_rules": [""], "band_c_error_keys": []},
                           {"band_c_rules": ["  "], "band_c_error_keys": []},
                           {"band_c_rules": ["reject_artist_credit", 5], "band_c_error_keys": []},
                           {"band_c_rules": ["reject_artist_credit"], "band_c_error_keys": [None]},
                           {"band_c_rules": ["reject_artist_credit"],
                            "band_c_error_keys": ["_no_signal", {}]}):
                with self.subTest(broken=broken):
                    policy._BANDS = broken
                    self.assertIsNone(sd.band_c_causes())
                    self.assertIsNone(sd.hold_causes(verdict))
                    self.assertEqual(sd.never_asked_cause((), None), "bands_table_unreadable")
                    self.assertEqual(sd.core_refusal_route(["proof_required"], (), None), "hold")
                    # the route a refused row takes, with and without core's validator_hold
                    for reasons in (["proof_required"], ["proof_required", "validator_hold"]):
                        self.assertEqual(sd.core_refusal_route(
                            reasons, ("reject_publisher_label_credit",), None), "hold")
                    # and the one reading every sender uses holds too
                    self.assertEqual(policy.never_ask(verdict, ["Mixing"]), "bands_table_unreadable")
        finally:
            policy._BANDS = kept
        self.assertEqual(sd.hold_causes(verdict), ["review_big_track_without_trusted_credit"])

    def test_the_fraud_class_and_the_hard_codes_rest_on_the_validator_s_own_record(self):
        """``hold_reason_codes`` is the validator's machine record of why a verdict was not
        an approval; a hard code there is a hard cause here. A ``fraud_hold`` that is
        present but is not a mapping with a decision is unmeasured, never "no hold";
        absent or null is simply no fraud hold; the score codes are not a hold."""
        askable = {"rule_risk_percent": {"review_big_track_without_trusted_credit": 40}}
        self.assertEqual(
            sd.hold_causes({**askable, "hold_reason_codes": ["review_held_submitter"]}),
            ["review_big_track_without_trusted_credit", "review_held_submitter"])
        self.assertEqual(
            sd.hold_causes({**askable, "hold_reason_codes":
                            ["risk_score_at_or_above_threshold", "score:track_credit"]}),
            ["review_big_track_without_trusted_credit"])
        self.assertEqual(sd.hold_causes({**askable, "fraud_hold": None}),
                         ["review_big_track_without_trusted_credit"])
        self.assertEqual(sd.hold_causes(askable), ["review_big_track_without_trusted_credit"])
        self.assertIsNone(sd.hold_causes({**askable, "fraud_hold": "hold"}))
        self.assertIsNone(sd.hold_causes({**askable, "fraud_hold": {"decision": 5}}))
        self.assertIsNone(sd.hold_causes({**askable, "fraud_hold": {}}))
        self.assertEqual(sd.hold_causes({**askable, "fraud_hold": {"decision": "hold"}}),
                         ["fraud_hold", "review_big_track_without_trusted_credit"])
    def test_the_causes_ride_the_plan_on_approve_and_ask_rows_and_survive_a_round_trip(self):
        precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9999)}]
        db = snapshot([row(1, precedent_key="k", hold_causes=["review_role_cardinality", "class_c"]),
                       row(2, precedent_key="k", hold_causes=[]),
                       row(3, precedent_key="k"),
                       row(4, precedent_key="k", hold_causes="[1, 2]"),
                       row(5, hold_causes=["review_held_submitter"]),
                       row(6, hold_causes=["review_held_submitter"], asked_at="2026-09-01T00:00:00Z",
                           expires_at="2026-10-01T00:00:00Z")],
                      precedent=precedent)
        decisions = sd.plan(db, now=NOW)
        self.assertEqual([(d.outcome, d.hold_causes) for d in decisions], [
            ("approve", ("class_c", "review_role_cardinality")),
            ("approve", ()),
            ("approve", None),
            ("approve", None),      # a malformed value is not measured
            # an ask row carries them too: the ask path must not ask about a cause no
            # document clears (split_asks)
            ("ask", ("review_held_submitter",)),
            ("cannot_confirm", None),  # a row that ends in no message carries none
        ])
        again = sd.parse_plan(sd.serialize(decisions))
        self.assertEqual([d.hold_causes for d in again], [d.hold_causes for d in decisions])
        self.assertEqual(sd.serialize(again), sd.serialize(decisions))
        # a plan written before the fields existed reads as not measured
        old = [json.dumps({k: v for k, v in d.as_row().items()
                           if k not in ("hold_causes", "editing_burst")})
               for d in decisions]
        self.assertEqual([d.hold_causes for d in sd.parse_plan("\n".join(old))], [None] * 6)
        self.assertEqual([d.editing_burst for d in sd.parse_plan("\n".join(old))], [None] * 6)

    def test_a_snapshot_file_made_before_the_causes_gains_the_column(self):
        with tempfile.TemporaryDirectory() as td:
            path = str(Path(td) / "snap.sqlite")
            before = sd.SNAPSHOT_SCHEMA.replace("  claimed_roles     TEXT,", "  claimed_roles     TEXT")
            before = "\n".join(ln for ln in before.splitlines() if "hold_causes" not in ln
                               and "Why the validator holds" not in ln and "of causes ([]" not in ln)
            old = sqlite3.connect(path)
            old.executescript(before)
            self.assertNotIn("hold_causes", {r[1] for r in old.execute("PRAGMA table_info(requests)")})
            old.close()
            db = sd.open_snapshot(path)
            sd.load_snapshot(db, [row(1, hold_causes=["class_c"])])
            self.assertEqual(db.execute("SELECT hold_causes FROM requests").fetchall(),
                             [('["class_c"]',)])
            db.close()

    def test_the_newest_verdict_wins_even_when_it_is_soft(self):
        with tempfile.TemporaryDirectory() as td:
            proofs = self._proof_store(td, [
                ("b" * 64, "r1", "FORGED_LIKELY", "2026-11-01T00:00:00Z"),
                ("c" * 64, "r1", "UNDETERMINED", "2026-11-02T00:00:00Z"),
                ("d" * 64, "r1", "VERIFIED", "2026-11-03T00:00:00Z"),
                ("e" * 64, "r2", "SUSPECT", "2026-11-03T00:00:00Z"),
                # a re-analysis under a newer analyzer: the soft verdict must clear the
                # older approval rather than resurrecting it
                ("f" * 64, "r3", "GENUINE", "2026-11-01T00:00:00Z"),
                ("g" * 64, "r3", "PLAUSIBLE", "2026-11-04T00:00:00Z"),
            ])
            facts = sd.proof_facts(proofs)
        self.assertEqual(facts["r1"]["proof_verdict"], "approve")
        self.assertEqual(facts["r1"]["proof_id"], "d" * 64)
        self.assertIsNone(facts["r2"]["proof_verdict"], "a soft verdict is not a decision")
        self.assertIsNone(facts["r3"]["proof_verdict"], "the newest verdict wins, soft or not")
        self.assertIsNone(facts["r3"]["proof_id"], "a soft verdict is never an anchor")
        self.assertEqual(facts["r3"]["proof_received_at"], "2026-11-04T00:00:00Z")

    def test_an_unreadable_proof_store_refuses_rather_than_asking_every_user(self):
        with tempfile.TemporaryDirectory() as td:
            bad = str(Path(td) / "proof.sqlite")
            Path(bad).write_bytes(b"not a database")
            with self.assertRaises(sd.DrainError):
                sd.proof_facts(bad)

    def test_decided_rows_become_per_claimant_precedents(self):
        decided = [
            ("d1", "approved", "u1", "trk-1", '{Mixing Engineer,"Mastering Engineer"}'),
            ("d2", "rejected", "u2", "trk-2", '{Producer}'),
            ("d3", "approved", "u3", "", '{Producer}'),
        ]

        def q(_sql):
            return decided
        rows, precedent = sd.decided_facts(q)
        self.assertEqual(len(rows), 3)
        by_key = {p["precedent_key"]: p for p in precedent}
        approve = by_key[sd.claim_key("u1", "trk-1", ["Mixing Engineer", "Mastering Engineer"])]
        self.assertEqual((approve["outcome"], approve["request_id"]), ("approve", "d1"))
        refuse = by_key[sd.claim_key("u2", "trk-2", ["Producer"])]
        self.assertEqual((refuse["outcome"], refuse["request_id"]), ("refuse", "d2"))
        self.assertEqual(len(precedent), 2, "a row with no track yields no precedent")

    # ── a bounded snapshot (``snapshot --max-rows``) ────────────────────────────

    @staticmethod
    def _trk(n):
        return f"{n:08x}-1111-4111-8111-111111111111"

    @staticmethod
    def _filtering_replica(pending, decided):
        """A replica that answers the statement it is sent: a pending read honours its
        LIMIT, a decided read honours its ``trackid IN`` / ``id IN`` list. ``decided`` may
        be a list or a callable giving an iterator, so a large population is never built
        unless a statement really asks for all of it."""
        import re  # noqa: PLC0415 - only this double parses SQL

        calls = []

        def ids_of(sql, column):
            m = re.search(column + r" IN \(([^)]*)\)", sql)
            return None if m is None else set(re.findall(r"UUID '([0-9a-f-]{36})'", m.group(1)))

        def q(sql):
            calls.append(sql)
            tail = sql.rsplit("LIMIT", 1)
            n = int(tail[1]) if len(tail) == 2 and tail[1].strip().isdigit() else None
            if "status IN ('approved', 'rejected')" not in sql:
                return list(pending)[:n]
            source = decided() if callable(decided) else decided
            tracks, ids = ids_of(sql, "trackid"), ids_of(sql, r"\bid")
            if tracks is not None:
                source = (r for r in source if r[3] in tracks)
            elif ids is not None:
                source = (r for r in source if r[0] in ids)
            return list(source)[:n]         # a cut statement is answered cut
        return q, calls

    def _plan_of(self, td, rows):
        path = str(Path(td) / f"snap-{len(rows)}.jsonl")
        with open(path, "w") as fh:
            for r in rows:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
        return {d.request_id: d for d in sd.plan(sd._build_snapshot(_args(snapshot=path)), now=NOW)}

    def _claims(self):
        """Six pending requests and a decided population in which a cut read lies.

        Track 1 holds user 1001's claim REJECTED first and APPROVED later, with other
        accounts' decisions between them. Read whole, the claim has an approve precedent;
        read cut after the rejection, it reads as refused.
        """
        t = self._trk
        pending = [
            (rid(1), "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
             "{}", "{}", t(1), "{Mixing Engineer}"),
            # names a decided request on ANOTHER track as its duplicate
            (rid(2), "1002", "p2", "user_verification_needed", "2026-11-01T00:00:00Z",
             json.dumps({"duplicate_of": rid(90)}), "{}", t(2), "{Producer}"),
            (rid(3), "1003", "p3", "unverified", "2026-11-01T00:00:00Z",
             "{}", "{}", t(2), "{Producer}"),
            (rid(4), "1004", "p4", "user_verification_needed", "2026-11-01T00:00:00Z",
             "{}", "{}", t(3), "{Songwriter}"),
            (rid(5), "1005", "p5", "user_verification_needed", "2026-11-01T00:00:00Z",
             "{}", "{}", t(4), "{Songwriter}"),
            (rid(6), "1006", "p6", "user_verification_needed", "2026-11-01T00:00:00Z",
             "{}", "{}", t(5), "{Composer}"),
        ]
        decided = [(rid(10), "rejected", "1001", t(1), "{Mixing Engineer}")]
        decided += [(rid(100 + i), "approved", str(5000 + i), t(1), "{Mixing Engineer}")
                    for i in range(40)]
        decided += [
            (rid(11), "approved", "1001", t(1), "{Mixing Engineer}"),
            (rid(12), "rejected", "1003", t(2), "{Producer}"),
            (rid(13), "approved", "1004", t(3), "{Songwriter}"),
            (rid(14), "approved", "1006", t(5), "{Composer}"),
            # on a track no pending row claims: the duplicate target, and its neighbour
            (rid(90), "approved", "1002", t(9), "{Producer}"),
            (rid(91), "rejected", "1002", t(9), "{Producer}"),
        ]
        return pending, decided

    def test_a_bounded_snapshot_keeps_the_full_precedent_for_its_tracks(self):
        pending, decided = self._claims()
        with tempfile.TemporaryDirectory() as td:
            q, _calls = self._filtering_replica(pending, decided)
            proofs = self._proof_store(td, [])
            full_rows = sd.replica_snapshot_rows(q, proof_store_path=proofs)
            full = self._plan_of(td, full_rows)
            self.assertEqual(full[rid(1)].reason_code, "precedent_match")
            # r2 names an approved request of another track: nothing is closed, and a
            # decision on another track is no precedent for this claim
            self.assertEqual((full[rid(2)].rule, full[rid(2)].outcome), ("ask", "ask"))
            self.assertEqual(full[rid(3)].reason_code, "precedent_refuse")
            full_precedent = {r["precedent_key"]: r for r in full_rows
                              if r["__kind"] == "precedent"}
            for bound in (1, 2, 3, 4, 5, 6, 50):
                with self.subTest(bound=bound):
                    rows = sd.replica_snapshot_rows(q, proof_store_path=proofs, limit=bound)
                    kept = [r for r in rows if r["__kind"] == "request"]
                    self.assertEqual(len(kept), min(bound, len(pending)))
                    precedent = {r["precedent_key"]: r for r in rows
                                 if r["__kind"] == "precedent"}
                    for r in kept:
                        key = r["precedent_key"]
                        self.assertEqual(precedent.get(key), full_precedent.get(key),
                                         "a kept request's precedent is the whole population's")
                    for key, row in precedent.items():
                        self.assertEqual(row, full_precedent[key],
                                         "no precedent the whole population does not give")
                    plan = self._plan_of(td, rows)
                    self.assertEqual(sorted(plan), sorted(r["request_id"] for r in kept))
                    for request_id, decision in plan.items():
                        self.assertEqual(decision, full[request_id],
                                         "a bounded plan decides its rows as the full plan does")

    def test_a_duplicate_target_read_by_id_sets_no_precedent(self):
        """r90 is read because r2 names it. The rest of its track was not read, so the
        approval is a decided row and nothing more: r91's rejection was never seen, and a
        key built from half a track's decisions is not a precedent."""
        pending, decided = self._claims()
        q, calls = self._filtering_replica(pending, decided)
        rows, precedent = sd.decided_facts(q, pending=[
            {"request_id": rid(2), "track_id": self._trk(2), "duplicate_of": rid(90)}])
        self.assertEqual(sorted(r["request_id"] for r in rows), [rid(12), rid(90)])
        self.assertEqual([p["request_id"] for p in precedent], [rid(12)])
        self.assertEqual(len(calls), 2, "one read by track, one by id")
        self.assertIn(f"id IN (UUID '{rid(90)}')", calls[1])

    def test_a_bounded_decided_read_is_filtered_and_paged_never_cut(self):
        tracks = [self._trk(i) for i in range(450)]
        pending = [(rid(i + 1), str(1000 + i), f"p{i}", "unverified", "2026-11-01T00:00:00Z",
                    "{}", "{}", tracks[i], "{Producer}") for i in range(450)]
        decided = [(rid(10_000 + i), "approved", str(1000 + i), tracks[i], "{Producer}")
                   for i in range(450)]
        with tempfile.TemporaryDirectory() as td:
            q, calls = self._filtering_replica(pending, decided)
            rows = sd.replica_snapshot_rows(q, proof_store_path=self._proof_store(td, []),
                                            limit=450)
        self.assertTrue(calls[0].rstrip().endswith("LIMIT 450"), "the pending read is bounded")
        reads = calls[1:]
        self.assertEqual(len(reads), 3, "450 tracks at 200 a statement")
        named: list[str] = []
        for sql in reads:
            self.assertNotIn("LIMIT", sql, "a decided read is never cut")
            ids = sql.split("trackid IN (", 1)[1].split(")", 1)[0].split(", ")
            self.assertLessEqual(len(ids), sd.DECIDED_CHUNK)
            named += [i[len("UUID '"):-1] for i in ids]
        self.assertEqual(sorted(named), sorted(tracks), "every track once, none dropped")
        self.assertEqual(sum(r["__kind"] == "decided" for r in rows), 450)
        self.assertEqual(sum(r["__kind"] == "precedent" for r in rows), 450)

    def test_an_unbounded_snapshot_reads_the_two_statements_unchanged(self):
        pending, decided = self._claims()
        for limit in (None, 0, -5):
            with self.subTest(limit=limit), tempfile.TemporaryDirectory() as td:
                q, calls = self._filtering_replica(pending, decided)
                rows = sd.replica_snapshot_rows(q, proof_store_path=self._proof_store(td, []),
                                                limit=limit)
                self.assertEqual(len(calls), 2, "the pending read and the decided read")
                for sql in calls:
                    self.assertNotIn("LIMIT", sql, "an unbounded read is never cut")
                    self.assertNotIn("IN (UUID", sql, "an unbounded read names no rows")
                self.assertEqual(sum(r["__kind"] == "request" for r in rows), len(pending))
                self.assertEqual(sum(r["__kind"] == "decided" for r in rows), len(decided))

    def test_max_rows_bounds_what_the_snapshot_holds_in_memory(self):
        """20,000 decided requests over 2,000 tracks. A snapshot bounded to 20 pending rows
        reads the 200 decided requests on their tracks and never holds the rest."""
        import tracemalloc  # noqa: PLC0415 - only this test measures memory

        tracks = [self._trk(i) for i in range(2000)]
        pending = [(rid(i + 1), str(1000 + i), f"p{i}", "unverified", "2026-11-01T00:00:00Z",
                    "{}", "{}", tracks[i], "{Producer}") for i in range(2000)]

        def decided():
            return ((rid(100_000 + i), "approved", str(9000 + i), tracks[i % 2000], "{Producer}")
                    for i in range(20_000))

        def peak(limit):
            with tempfile.TemporaryDirectory() as td:
                q, _calls = self._filtering_replica(pending, decided)
                proofs = self._proof_store(td, [])
                tracemalloc.start()
                try:
                    rows = sd.replica_snapshot_rows(q, proof_store_path=proofs, limit=limit)
                    return tracemalloc.get_traced_memory()[1], rows
                finally:
                    tracemalloc.stop()

        whole, all_rows = peak(None)
        bounded, rows = peak(20)
        self.assertEqual(sum(r["__kind"] == "decided" for r in all_rows), 20_000)
        self.assertEqual(sum(r["__kind"] == "request" for r in rows), 20)
        self.assertEqual(sum(r["__kind"] == "decided" for r in rows), 200,
                         "all ten decided requests on each of the 20 tracks, and no other")
        self.assertLess(bounded * 10, whole,
                        f"bounded peak {bounded} bytes against {whole} unbounded")

    def test_a_value_that_is_not_a_uuid_is_never_put_in_a_statement(self):
        calls = []

        def q(sql):
            calls.append(sql)
            return []

        for track in ("trk-1", "x') OR 1=1 --", self._trk(1) + "'"):
            with self.subTest(track=track):
                with self.assertRaises(sd.DrainError) as ctx:
                    sd.decided_facts(q, pending=[{"request_id": rid(1), "track_id": track}])
                self.assertIn("is not a UUID", str(ctx.exception))
        self.assertEqual(calls, [], "refused before any statement was built")
        # no track, no claim key: nothing to read, and that is not an error
        self.assertEqual(sd.decided_facts(q, pending=[{"request_id": rid(1), "track_id": ""}]),
                         ([], []))
        # a duplicate target that is not a request id names nothing to read
        self.assertEqual(sd.decided_facts(q, pending=[
            {"request_id": rid(1), "track_id": "", "duplicate_of": "not-a-request"}]), ([], []))
        self.assertEqual(calls, [])

    def test_the_cli_bounds_the_pending_rows_and_keeps_their_decided_rows(self):
        from credit_review import verify_notify  # noqa: PLC0415 - patched below

        pending, decided = self._claims()
        for max_rows, want in (
                # r1 and r2: track 1 (42 decided) + track 2 (1) + the duplicate target r90
                (2, {"rows": 2 + 44 + 42, "bounded": 2, "decided": 44, "precedent": 42}),
                (0, {"rows": 6 + 47 + 45, "decided": 47, "precedent": 45})):
            with self.subTest(max_rows=max_rows), tempfile.TemporaryDirectory() as td:
                q, _calls = self._filtering_replica(pending, decided)
                out = Path(td) / "snap.jsonl"
                err = io.StringIO()
                with mock.patch.object(verify_notify, "trino", q), \
                        mock.patch.object(sd, "proof_claims", lambda _p=None: {}), \
                        contextlib.redirect_stderr(err):
                    rc = sd._main(["snapshot", "--out", str(out), "--max-rows", str(max_rows),
                                   "--ledger", str(Path(td) / "none.sqlite")])
                self.assertEqual(rc, 0)
                stats = json.loads(err.getvalue().strip().splitlines()[-1])
                self.assertEqual({k: stats.get(k) for k in want}, want)
                self.assertEqual("bounded" in stats, bool(max_rows))
                kinds = [json.loads(line)["__kind"] for line in out.read_text().splitlines()]
                self.assertEqual(len(kinds), want["rows"])
                self.assertEqual(kinds.count("request"), max_rows or len(pending),
                                 "--max-rows counts pending rows; their facts are not cut off")
                self.assertEqual(kinds.count("decided"), want["decided"])
                self.assertEqual(kinds.count("precedent"), want["precedent"])

    def test_one_claimants_approval_is_not_another_claimants_precedent(self):
        decided = [("d1", "approved", "u1", "trk-1", '{Mixing Engineer}')]

        def q(_sql):
            return decided
        _, precedent = sd.decided_facts(q)
        self.assertEqual(len(precedent), 1)
        self.assertNotEqual(sd.claim_key("u1", "trk-1", ["Mixing Engineer"]),
                            sd.claim_key("u2", "trk-1", ["Mixing Engineer"]))
        self.assertIsNone(sd.claim_key("", "trk-1", ["Mixing Engineer"]),
                          "a row with no claimant cannot produce a precedent key")

    def test_an_unreadable_ledger_refuses_rather_than_assuming_nobody_was_asked(self):
        with tempfile.TemporaryDirectory() as td:
            bad = str(Path(td) / "bad.sqlite")
            Path(bad).write_bytes(b"not a database")
            with self.assertRaises(sd.DrainError):
                sd.asked_at_by_request(bad)

    def test_a_missing_ledger_means_no_ask_history(self):
        self.assertEqual(sd.asked_at_by_request("/nonexistent/ledger.sqlite"), {})

    def test_ask_history_is_keyed_by_request_not_by_account(self):
        """QA review 2: asking about request A must not expire request B for the same user."""
        with tempfile.TemporaryDirectory() as td:
            path = str(Path(td) / "ledger.sqlite")
            db = sqlite3.connect(path)
            db.executescript("""
                CREATE TABLE verify_messages (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, status TEXT,
                  sent_at TEXT, account_id TEXT, request_ids_json TEXT NOT NULL);
            """)
            db.execute("INSERT INTO verify_messages (campaign, status, sent_at, account_id,"
                       " request_ids_json) VALUES ('proof-need-ask','sent',"
                       " '2026-10-01T00:00:00Z','u1','[\"req-A\"]')")
            db.commit()
            db.close()
            asked = sd.asked_at_by_request(path)
        self.assertEqual(asked, {"req-A": "2026-10-01T00:00:00Z"})
        self.assertNotIn("req-B", asked)

    def test_the_snapshot_query_is_bounded_to_pending_and_not_deleted(self):
        db = sqlite3.connect(":memory:")
        db.create_function("json_format", 1, lambda v: v)
        db.execute(
            "CREATE TABLE credit_requests ("
            " id TEXT, userid TEXT, profileid TEXT, status TEXT, createdat TEXT,"
            " verificationdata TEXT, metadata TEXT, trackid TEXT, credits TEXT, deletedat TEXT)")
        rows = [("alive", "1", "p1", "user_verification_needed", "2026-11-01", "{}", "{}", "t", "{}", None),
                ("soft", "2", "p2", "unverified", "2026-11-01", "{}", "{}", "t", "{}", "2026-11-02"),
                ("done", "3", "p3", "approved", "2026-11-01", "{}", "{}", "t", "{}", None)]
        db.executemany("INSERT INTO credit_requests VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
        sql = sd.SNAPSHOT_SQL.replace("postgresql_core.public.credit_requests", "credit_requests")
        self.assertEqual([r[0] for r in db.execute(sql)], ["alive"])


class RealSourcesTests(unittest.TestCase):
    """The documented `snapshot` then `plan --snapshot` contract, over real sources.

    The rules that decide (precedent, proof verdict) and the one that only sets a row aside
    (duplicate) each depend on a fact that lives OUTSIDE the pending row: the decided
    history, the proof store, and whether the original a request names is decided. A fixture that feeds those facts in `verificationData` proves
    nothing, so this drives the snapshot builder's real queries and then the ladder.
    """

    def _proof_store(self, td, rows):
        path = str(Path(td) / "proof.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO verdicts (proof_id, request_id, verdict, created_at)"
                       " VALUES (?,?,?,?)", rows)
        db.commit()
        db.close()
        return path

    def test_the_documented_two_command_contract_decides_from_the_real_sources(self):
        with tempfile.TemporaryDirectory() as td:
            proofs = self._proof_store(td, [
                # the store keys a verdict by CLAIM, "<request>#<Role>", never by request
                ("f" * 64, f"{rid(4)}#Songwriter", "GENUINE", "2026-11-05T00:00:00Z")])
            pending = [
                # r1 names r10, approved on another track: nothing is closed, and r10 is
                # no precedent for this claim, so r1 is asked
                (rid(1), "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
                 json.dumps({"duplicate_of": rid(10)}), "{}", "trk-1", '{Mixing Engineer}'),
                # r2 is the SAME claimant as approved r11, same claim: approve on precedent
                (rid(2), "1002", "p2", "user_verification_needed", "2026-11-01T00:00:00Z",
                 "{}", "{}", "trk-1", '{Mixing Engineer}'),
                # r3 is the same claimant as rejected r12: cannot confirm, no write
                (rid(3), "1003", "p3", "unverified", "2026-11-01T00:00:00Z",
                 "{}", "{}", "trk-2", '{Producer}'),
                # r4 has a genuine proof: approve
                (rid(4), "1004", "p4", "user_verification_needed", "2026-11-01T00:00:00Z",
                 "{}", "{}", "trk-4", '{Songwriter}'),
                # r5 is a DIFFERENT claimant with r11's exact claim: no precedent, so ask
                (rid(5), "1005", "p5", "user_verification_needed", "2026-11-01T00:00:00Z",
                 "{}", "{}", "trk-1", '{Mixing Engineer}'),
            ]
            decided = [
                (rid(10), "approved", "1001", "trk-10", '{Mixing Engineer}'),
                (rid(11), "approved", "1002", "trk-1", '{Mixing Engineer}'),
                (rid(12), "rejected", "1003", "trk-2", '{Producer}'),
            ]

            def q(sql):
                return list(decided) if "status IN ('approved', 'rejected')" in sql else list(pending)

            rows = sd.replica_snapshot_rows(q, proof_store_path=proofs)
            path = str(Path(td) / "snap.jsonl")
            with open(path, "w") as fh:
                for r in rows:
                    fh.write(json.dumps(r, sort_keys=True) + "\n")
            db = sd._build_snapshot(_args(snapshot=path))
        decisions = {d.request_id: d for d in sd.plan(db, now=NOW)}
        self.assertEqual((decisions[rid(1)].rule, decisions[rid(1)].outcome), ("ask", "ask"))
        self.assertEqual(decisions[rid(2)].outcome, "approve")
        self.assertEqual(decisions[rid(2)].reason_code, "precedent_match")
        self.assertEqual(decisions[rid(3)].outcome, "cannot_confirm")
        self.assertEqual(decisions[rid(3)].reason_code, "precedent_refuse")
        self.assertEqual(decisions[rid(4)].outcome, "approve")
        self.assertEqual(decisions[rid(4)].reason_code, "proof_verdict_approve")
        self.assertEqual(decisions[rid(4)].evidence_anchor, "f" * 64)
        self.assertEqual(decisions[rid(5)].outcome, "ask",
                         "another account's approval is not this account's precedent")

    def test_a_row_whose_fact_cannot_be_resolved_is_unmatched_not_asked(self):
        with tempfile.TemporaryDirectory() as td:
            proofs = self._proof_store(td, [])
            pending = [
                # says it duplicates something, but the original was never decided (or is
                # older than the decided window): the fact cannot be resolved
                (rid(1), "1001", "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
                 json.dumps({"duplicate_of": rid(99)}), "{}", "trk-1", '{Mixing Engineer}'),
            ]

            def q(sql):
                return list(pending) if "status IN ('approved', 'rejected')" not in sql else []
            rows = sd.replica_snapshot_rows(q, proof_store_path=proofs)
            path = str(Path(td) / "snap.jsonl")
            with open(path, "w") as fh:
                for r in rows:
                    fh.write(json.dumps(r, sort_keys=True) + "\n")
            db = sd._build_snapshot(_args(snapshot=path))
            decisions = sd.plan(db, now=NOW)
            ledger = sd.open_ledger(str(Path(td) / "l.sqlite"))
        self.assertEqual([d.outcome for d in decisions], [sd.UNMATCHED])
        stats = sd.apply(decisions, ledger, commit_writes=False, now=NOW)
        self.assertEqual(stats["unmatched"], 1)
        self.assertEqual(stats["applied"], 0)
        self.assertEqual(stats["would_write"], 0)


def _args(**kw):
    base = {"snapshot": None, "decided": None, "precedent": None, "ask_window_days": sd.ASK_WINDOW_DAYS}
    base.update(kw)
    return type("Args", (), base)()


class WrapperAcceptsTheRealDigestTests(unittest.TestCase):
    """The digest the drain EMITS must pass the wrapper's predicate, not a hand-typed one.

    The bats suite feeds literal ``v1`` digests, so it cannot catch a version string the
    drain formats differently (``v`` + ``r1`` = ``vr1``). This runs the real predicate
    from both wrapper copies against the real ``drain_evidence`` output, which is the
    contract that decides whether a write is allowed.
    """

    WRAPPERS = (
        "skills-all/muso-ops-admin/scripts/muso-admin-api.sh",
        "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh",
    )

    def setUp(self):
        # A stub verifier that records the parts the wrapper parsed out of the digest and
        # exits 0. The wrapper's job is to parse and DELEGATE; verify_anchor's own tests
        # cover the verification. This proves the delegation happens with the right args.
        #
        # The stub lives in a MIRRORED tree, at the path the predicate derives from its own
        # location. That derivation is the fix for QA review 3: HYDRA_ROOT is caller-
        # controlled, so a caller could point the gate at a substitute verifier. Nothing
        # here can be overridden by an environment variable.
        self.root = Path(tempfile.mkdtemp())
        (self.root / "scripts/credit_review").mkdir(parents=True)
        self.argv_log = self.root / "verifier-argv.json"
        (self.root / "scripts/credit_review/verify_anchor.py").write_text(
            "import json, sys\n"
            f"open({str(self.argv_log)!r}, 'w').write(json.dumps(sys.argv[1:]))\n"
            "sys.exit(0)\n")
        self.token = self.root / "scale-drain.token"
        self.token.write_text("s3cret\n")
        self.token.chmod(0o600)
        # The registry is read from the tree the wrapper sits in, so the mirrored tree
        # carries a copy of the real one - exactly where a deploy puts it.
        self.registry = self.root / "policies/credit-approval-automation.json"
        self.registry.parent.mkdir()
        self.registry.write_text(REGISTRY.read_text())

    #: The one line, in each wrapper, that names the token file the approve gate reads.
    #: A positive test cannot write /etc/hydra, so it rewrites
    #: THIS literal in its scratch copy. There is deliberately no environment seam to do
    #: it with: that seam was the finding. The denial tests run the text unmodified.
    TOKEN_PIN = 'local drain_token_file="/etc/hydra/scale-drain.token"'
    #: The helpers the predicate calls. Extracted with it, so what runs is their real
    #: text and nothing a test wrote.
    HELPERS = ("scale_drain_root", "scale_drain_registry", "scale_drain_token_ok")

    def _predicate(self, wrapper: str, fn: str, excerpt: str, body: str,
                   path: str = "/admin/credit-requests", *,
                   pinned: bool = False,
                   extra_env: dict[str, str] | None = None,
                   invoke_as: Path | None = None) -> subprocess.CompletedProcess:
        # Materialise the REAL predicate text in a mirrored tree, so ${BASH_SOURCE[0]}
        # resolves the way it does in production and the wrapper-root walk is exercised.
        rel = Path(wrapper)
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        real = (SCRIPTS.parent / wrapper).read_text()
        self.assertEqual(real.count(self.TOKEN_PIN), 1,
                         f"{wrapper}: the token path is no longer the one pinned literal")
        text = "".join(
            f"{name}() {{" + real.split(f"\n{name}() {{", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
            for name in (*self.HELPERS, fn))
        if not pinned:
            text = text.replace(self.TOKEN_PIN, f'local drain_token_file="{self.token}"')
            self.assertNotIn("/etc/hydra/scale-drain.token", text)
        target.write_text(text + f'{fn} PUT "$1" "$2"\n')
        target.chmod(0o755)
        env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "MUSO_OPS_STATE_DIR": tempfile.mkdtemp(),
            "OPS_RUNLOG_DIR": tempfile.mkdtemp(),
            "MUSO_API_URL": "http://127.0.0.1:0/none",
            "MUSO_ADMIN_EMAIL": "test@example.com",
            "MUSO_ADMIN_PASSWORD": "x",
            # Neither registry variable is set: the predicate finds the registry itself.
            "SCALE_DRAIN": "1",
            "REQUESTER_EMAIL": "scale-drain@hydra-ops",
            "EVIDENCE_EXCERPT": excerpt,
            "SCALE_DRAIN_TOKEN": "s3cret",
            **(extra_env or {}),
        }
        # ``invoke_as`` is the path the caller RUNS (a symlink, say); the file is the same.
        return subprocess.run(["bash", str(invoke_as or target), path, body],
                              capture_output=True, text=True, env=env, check=False)

    def test_the_emitted_approve_digest_passes_both_wrappers(self):
        d = sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                        sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9),
                        profile_id=rid(7))
        body = json.dumps({"requestIds": [rid(1)], "status": "approved"})
        for wrapper in self.WRAPPERS:
            proc = self._predicate(wrapper, "is_scale_drain_approval",
                                   sd.drain_evidence(d), body)
            self.assertEqual(proc.returncode, 0, f"{wrapper} refused {sd.drain_evidence(d)!r}: {proc.stderr}")
            # the wrapper DELEGATES the anchor to the verifier, with the parts it parsed
            argv = json.loads(self.argv_log.read_text())
            self.assertEqual(argv[argv.index("--rule") + 1], "precedent")
            self.assertEqual(argv[argv.index("--anchor") + 1], rid(9))
            self.assertEqual(argv[argv.index("--request-id") + 1], rid(1))
            self.assertEqual(argv[argv.index("--profile-id") + 1], rid(7))

    def test_a_forged_digest_cannot_skip_the_verifier(self):
        """The digest is a claim; the verifier is what makes it a fact."""
        d = sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                        sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9),
                        profile_id=rid(7))
        body = json.dumps({"requestIds": [rid(1)], "status": "approved"})
        # a verifier that refuses (the anchor is not approved / not this claimant)
        (self.root / "scripts/credit_review/verify_anchor.py").write_text("import sys; sys.exit(1)\n")
        for wrapper in self.WRAPPERS:
            proc = self._predicate(wrapper, "is_scale_drain_approval",
                                   sd.drain_evidence(d), body)
            self.assertEqual(proc.returncode, 1, f"{wrapper} approved without a verified anchor")
            self.assertIn("anchor verification failed", proc.stderr)

    def test_a_missing_verifier_refuses_rather_than_passing(self):
        d = sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                        sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9),
                        profile_id=rid(7))
        body = json.dumps({"requestIds": [rid(1)], "status": "approved"})
        (self.root / "scripts/credit_review/verify_anchor.py").unlink()
        for wrapper in self.WRAPPERS:
            proc = self._predicate(wrapper, "is_scale_drain_approval",
                                   sd.drain_evidence(d), body)
            self.assertEqual(proc.returncode, 1, f"{wrapper} approved with no verifier")
            # The deployed tree is FOUND by its verifier, so a tree with no verifier is a
            # tree that cannot be located - and the registry is pinned to that tree, so
            # the refusal now comes one step earlier than the verifier call itself.
            self.assertIn("cannot be located", proc.stderr)
            self.assertFalse(self.argv_log.exists(), "a verifier ran from somewhere")

    def test_a_batch_body_is_refused(self):
        """One digest carries one anchor, so a batch would be unverified rows."""
        d = sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                        sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9),
                        profile_id=rid(7))
        body = json.dumps({"requestIds": [rid(1), rid(2)], "status": "approved"})
        for wrapper in self.WRAPPERS:
            proc = self._predicate(wrapper, "is_scale_drain_approval",
                                   sd.drain_evidence(d), body)
            self.assertEqual(proc.returncode, 1, f"{wrapper} accepted a batch on one anchor")

    def test_the_emitted_proof_digest_passes_both_wrappers(self):
        proof_id = "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f"
        d = sd.Decision(rid(1), "proof_verdict", "approve", "proof_verdict_approve",
                        sd.decision_key(rid(1), "proof_verdict", "approve"), evidence_anchor=proof_id,
                        profile_id=rid(7))
        body = json.dumps({"requestIds": [rid(1)], "status": "approved"})
        for wrapper in self.WRAPPERS:
            proc = self._predicate(wrapper, "is_scale_drain_approval",
                                   sd.drain_evidence(d), body)
            self.assertEqual(proc.returncode, 0, f"{wrapper} refused {sd.drain_evidence(d)!r}: {proc.stderr}")

    def _approve_call(self):
        d = sd.Decision(rid(1), "precedent", "approve", "precedent_match",
                        sd.decision_key(rid(1), "precedent", "approve"),
                        evidence_anchor=rid(9), profile_id=rid(7))
        return sd.drain_evidence(d), json.dumps({"requestIds": [rid(1)], "status": "approved"})

    def _gates(self):
        """The drain's one write, as ``(wrapper, fn, excerpt, body, path)``: every identity
        and registry case below runs against it in both wrapper copies."""
        for wrapper in self.WRAPPERS:
            yield (wrapper, "is_scale_drain_approval", *self._approve_call(),
                   "/admin/credit-requests")

    def test_a_caller_supplied_token_file_is_denied_by_the_wrapper(self):
        """QA review 4, finding 1. The attack, on the UNMODIFIED gate: the caller writes
        its own mode-600 file, names it in SCALE_DRAIN_TOKEN_FILE, and presents its
        contents. Before the pin that passed every check the gate had. It must be refused
        for the override itself, before the verifier is consulted."""
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                self.argv_log.unlink(missing_ok=True)
                proc = self._predicate(
                    wrapper, fn, excerpt, body, path=path, pinned=True,
                    extra_env={"SCALE_DRAIN_TOKEN_FILE": str(self.token)})
                self.assertEqual(proc.returncode, 1,
                                 f"{wrapper} accepted a caller-selected token file")
                self.assertIn("SCALE_DRAIN_TOKEN_FILE is set", proc.stderr)
                self.assertIn("cannot be redirected", proc.stderr)
                self.assertFalse(self.argv_log.exists())

    def test_the_override_is_denied_even_when_everything_else_is_valid(self):
        """Denied, not ignored. With the token file in place and the right token
        presented the close is allowed; the ONLY change is the variable - set to the very
        file the gate already reads - and the close is refused. A gate that merely
        ignored the override would pass this call."""
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                ok = self._predicate(wrapper, fn, excerpt, body, path=path)
                self.assertEqual(ok.returncode, 0, ok.stderr)
                self.argv_log.unlink()
                for value in (str(self.token), ""):
                    proc = self._predicate(
                        wrapper, fn, excerpt, body, path=path,
                        extra_env={"SCALE_DRAIN_TOKEN_FILE": value})
                    self.assertEqual(proc.returncode, 1,
                                     f"{wrapper} ignored SCALE_DRAIN_TOKEN_FILE={value!r}")
                    self.assertIn("SCALE_DRAIN_TOKEN_FILE is set", proc.stderr)
                    self.assertFalse(self.argv_log.exists())

    def test_a_caller_supplied_token_is_denied_by_the_wrapper(self):
        """A SCALE_DRAIN_TOKEN the caller chose is refused unless it is exactly what the
        pinned file holds - and the verifier is not consulted on its behalf."""
        for wrapper, fn, excerpt, body, path in self._gates():
            for value in ("attacker-chosen", "S3CRET", "s3cret ", ""):
                with self.subTest(wrapper=wrapper, gate=fn, token=value):
                    self.argv_log.unlink(missing_ok=True)
                    proc = self._predicate(
                        wrapper, fn, excerpt, body, path=path,
                        extra_env={"SCALE_DRAIN_TOKEN": value})
                    self.assertEqual(proc.returncode, 1,
                                     f"{wrapper} accepted SCALE_DRAIN_TOKEN={value!r}")
                    self.assertIn("SCALE_DRAIN_TOKEN does not match", proc.stderr)
                    self.assertFalse(self.argv_log.exists())

    @unittest.skipIf(os.path.exists("/etc/hydra/scale-drain.token"),
                     "this host carries the real drain token")
    def test_a_callers_own_token_is_denied_against_the_real_pinned_path(self):
        """No override at all, the unmodified gate, and a token the caller made up: the
        gate looks only at /etc/hydra/scale-drain.token, which the caller cannot create."""
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                proc = self._predicate(wrapper, fn, excerpt, body, path=path, pinned=True)
                self.assertEqual(proc.returncode, 1)
                self.assertIn("/etc/hydra/scale-drain.token is missing", proc.stderr)
                self.assertFalse(self.argv_log.exists())

    def test_the_approval_checks_the_drains_identity_first(self):
        """QA review 5: the approve exception had no identity at all - the requester, the
        flag and the digest are all things a caller asserts. The predicate calls the one
        helper, in both wrapper copies, and carries no token path of its own."""
        for wrapper in self.WRAPPERS:
            real = (SCRIPTS.parent / wrapper).read_text()
            body = real.split("\nis_scale_drain_approval() {", 1)[1].split("\n}\n", 1)[0]
            self.assertIn('scale_drain_token_ok "an approval" || return 1', body, wrapper)
            self.assertNotIn("drain_token_file", body, wrapper)
            # the identity is checked before the registry, the digest or the verifier
            self.assertLess(body.index("scale_drain_token_ok"),
                            body.index("scale_drain_registry"), wrapper)

    # ── the approval registry (QA review 5) ──────────────────────────────────
    def _callers_registry(self, approved: bool = True) -> Path:
        """A registry the caller wrote: the real one, with the drain's entry as the
        caller would like it to read."""
        doc = json.loads(REGISTRY.read_text())
        doc["automations"]["verification-scale-drain"]["approved"] = approved
        mine = self.root / "mine/policies/credit-approval-automation.json"
        mine.parent.mkdir(parents=True, exist_ok=True)
        mine.write_text(json.dumps(doc))
        return mine

    def _unapprove_the_deployed_registry(self) -> None:
        doc = json.loads(REGISTRY.read_text())
        doc["automations"]["verification-scale-drain"]["approved"] = False
        self.registry.write_text(json.dumps(doc))

    def test_the_drain_must_be_approved_in_the_deployed_registry(self):
        """The control: with the deployed registry saying no, nothing else matters."""
        self._unapprove_the_deployed_registry()
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                proc = self._predicate(wrapper, fn, excerpt, body, path=path)
                self.assertEqual(proc.returncode, 1)
                self.assertIn(f"is not approved in {self.registry}", proc.stderr)
                self.assertFalse(self.argv_log.exists())

    def test_a_caller_supplied_registry_is_denied(self):
        """The attack. The deployed registry has NOT approved the drain; the caller
        points the gate at an ``approved: true`` copy it wrote, by either variable. That
        used to be the whole of 'the captain recorded this decision'."""
        self._unapprove_the_deployed_registry()
        mine = self._callers_registry()
        overrides = ({"CREDIT_APPROVAL_REGISTRY": str(mine)},
                     {"HYDRA_ROOT": str(mine.parents[1])},
                     {"CREDIT_APPROVAL_REGISTRY": str(mine), "HYDRA_ROOT": str(self.root)})
        for wrapper, fn, excerpt, body, path in self._gates():
            for override in overrides:
                with self.subTest(wrapper=wrapper, gate=fn, override=sorted(override)):
                    self.argv_log.unlink(missing_ok=True)
                    proc = self._predicate(wrapper, fn, excerpt, body, path=path,
                                           extra_env=override)
                    self.assertEqual(proc.returncode, 1,
                                     f"{wrapper} read a caller-selected registry")
                    self.assertIn("cannot be redirected", proc.stderr)
                    self.assertIn(str(self.registry), proc.stderr)
                    self.assertFalse(self.argv_log.exists())

    def test_a_registry_override_is_denied_even_when_the_deployed_one_approves(self):
        """Denied, not ignored. The deployed registry approves the drain and the call is
        allowed; the ONLY change is a registry variable naming another file - one that
        approves it too - and the call is refused. A gate that quietly read the pinned
        file anyway would pass this."""
        mine = self._callers_registry()
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                ok = self._predicate(wrapper, fn, excerpt, body, path=path)
                self.assertEqual(ok.returncode, 0, ok.stderr)
                for override in ({"CREDIT_APPROVAL_REGISTRY": str(mine)},
                                 {"HYDRA_ROOT": str(mine.parents[1])}):
                    self.argv_log.unlink(missing_ok=True)
                    proc = self._predicate(wrapper, fn, excerpt, body, path=path,
                                           extra_env=override)
                    self.assertEqual(proc.returncode, 1, f"{wrapper} ignored {override}")
                    self.assertIn("cannot be redirected", proc.stderr)
                    self.assertFalse(self.argv_log.exists())

    def test_the_pinned_registry_named_explicitly_is_not_a_redirect(self):
        """The operations wrapper's other predicates default CREDIT_APPROVAL_REGISTRY to
        the deployed path, and a host may export it: naming the pinned file - directly,
        through HYDRA_ROOT, or through a symlink to it - changes nothing."""
        link = self.root / "registry-link.json"
        link.symlink_to(self.registry)
        for wrapper, fn, excerpt, body, path in self._gates():
            for override in ({"CREDIT_APPROVAL_REGISTRY": str(self.registry)},
                             {"HYDRA_ROOT": str(self.root)},
                             {"CREDIT_APPROVAL_REGISTRY": str(link)}):
                with self.subTest(wrapper=wrapper, gate=fn, override=sorted(override)):
                    proc = self._predicate(wrapper, fn, excerpt, body, path=path,
                                           extra_env=override)
                    self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_no_drain_predicate_reads_the_registry_path_from_the_environment(self):
        for wrapper in self.WRAPPERS:
            real = (SCRIPTS.parent / wrapper).read_text()
            for fn in ("is_scale_drain_approval",):
                body = real.split(f"\n{fn}() {{", 1)[1].split("\n}\n", 1)[0]
                self.assertIn('registry="$(scale_drain_registry)" || return 1', body, wrapper)
                self.assertNotIn("CREDIT_APPROVAL_REGISTRY", body, wrapper)
                self.assertNotIn("HYDRA_ROOT", body, wrapper)

    def test_a_symlink_to_the_wrapper_does_not_move_the_tree_it_trusts(self):
        """The same redirect without a variable: a symlink to the deployed wrapper, made
        in a tree the caller owns, beside a verifier that passes everything and a registry
        that approves everything. The walk starts from the wrapper's resolved path, so the
        deployed verifier - which refuses here - is the one that answers."""
        (self.root / "scripts/credit_review/verify_anchor.py").write_text(
            "import sys; sys.exit(1)\n")
        self._unapprove_the_deployed_registry()
        mine = self._callers_registry().parents[1]
        ran = mine / "callers-verifier-ran"
        (mine / "scripts/credit_review").mkdir(parents=True)
        (mine / "scripts/credit_review/verify_anchor.py").write_text(
            f"open({str(ran)!r}, 'w').close()\n")
        for wrapper, fn, excerpt, body, path in self._gates():
            with self.subTest(wrapper=wrapper, gate=fn):
                link = mine / wrapper
                link.parent.mkdir(parents=True, exist_ok=True)
                link.unlink(missing_ok=True)
                link.symlink_to(self.root / wrapper)
                proc = self._predicate(wrapper, fn, excerpt, body, path=path, invoke_as=link)
                self.assertEqual(proc.returncode, 1, f"{wrapper} trusted the caller's tree")
                self.assertIn(f"is not approved in {self.registry}", proc.stderr)
                self.assertFalse(ran.exists())


class CommitErrorTests(unittest.TestCase):
    """Only a duplicate decision_key means 'already applied'."""

    def test_a_duplicate_key_is_a_skip(self):
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            d = sd.Decision(rid(1), "ask", "ask", "no_rule_matched", sd.decision_key(rid(1), "ask", "ask"))
            self.assertTrue(sd._commit(db, d, 0, NOW))
            self.assertFalse(sd._commit(db, d, 0, NOW))

    def test_a_non_unique_constraint_error_is_not_swallowed(self):
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            db.execute("CREATE TRIGGER boom BEFORE INSERT ON applied BEGIN SELECT RAISE(ABORT, 'boom'); END")
            d = sd.Decision(rid(1), "ask", "ask", "no_rule_matched", sd.decision_key(rid(1), "ask", "ask"))
            with self.assertRaises(sqlite3.IntegrityError):
                sd._commit(db, d, 0, NOW)


class NoWriteRehearsalTests(unittest.TestCase):
    def test_a_rehearsal_reports_writes_without_poisoning_the_ledger(self):
        precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]
        decisions = sd.plan(snapshot([row(1, precedent_key="k"), row(2)], precedent=precedent),
                            now=NOW)
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            stats = sd.apply(decisions, db, shards=1, write_pool=1, writer=None,
                             commit_writes=False, now=NOW)
            applied = {r[0] for r in db.execute("SELECT decision_key FROM applied")}
        approve = next(d for d in decisions if d.outcome == "approve")
        ask = next(d for d in decisions if d.outcome == "ask")
        self.assertEqual(stats["would_write"], 1)
        self.assertEqual(stats["applied"], 1)
        self.assertNotIn(approve.decision_key, applied)
        self.assertIn(ask.decision_key, applied)


class ResumeTests(unittest.TestCase):
    def test_a_failed_row_behind_a_committed_row_is_retried(self):
        precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]
        decisions = sd.plan(snapshot([row(1, precedent_key="k"), row(2)], precedent=precedent),
                            now=NOW)
        attempts = []

        def writes_once(d):
            attempts.append(d.request_id)
            if len(attempts) == 1:
                raise sd.DrainWriteError("transient")

        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            first = sd.apply(decisions, db, shards=1, write_pool=1, writer=writes_once, now=NOW)
            self.assertEqual(first["errors"], 1)
            second = sd.apply(decisions, db, shards=1, write_pool=1, writer=writes_once, now=NOW,
                              reconciler=lambda d, planned_at: sd.NOT_LANDED)
            self.assertEqual(second["applied"], 1)
            self.assertTrue(sd.verify(decisions, db)["ok"])

    def test_a_complete_shard_is_skipped_on_restart(self):
        decisions = sd.plan(snapshot([row(i) for i in range(20)]), now=NOW)
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            first = sd.apply(decisions, db, shards=4, write_pool=1, now=NOW)
            self.assertEqual(first["applied"], 20)
            second = sd.apply(decisions, db, shards=4, write_pool=1, now=NOW)
            self.assertEqual(second["applied"], 0)
            self.assertEqual(second["skipped"], 20)


#: One apply in a child process whose writer performs the API write and then dies before
#: returning - a real SIGKILL between step 2 (the write) and step 3 (the confirm). argv:
#: scripts dir, plan, ledger, the file standing in for the API, and where to die.
CRASHING_APPLY = r"""
import os, signal, sys
sys.path.insert(0, sys.argv[1])
from credit_review import scale_drain as sd
plan, ledger, api, die = sys.argv[2:6]
def writer(d):
    if die == "before-write":
        os.kill(os.getpid(), signal.SIGKILL)
    with open(api, "a") as fh:
        fh.write(d.request_id + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.kill(os.getpid(), signal.SIGKILL)
sd.apply(sd.parse_plan(open(plan, "rb").read()), sd.open_ledger(ledger),
         shards=1, write_pool=1, writer=writer)
"""


class WriteAheadTests(unittest.TestCase):
    """Intent, write, confirm - and what a restart does with an intent nobody confirmed.

    QA review 5 of hydra#1883: ``apply`` wrote, then committed. A process that died in
    between left a request approved in the product and unknown to the ledger, and the next
    run could not repair it, because the gate refuses a request that is no longer pending.
    The row was reported missing forever.
    """

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.addCleanup(self.td.cleanup)
        self.ledger = str(Path(self.td.name) / "ledger.sqlite")
        self.api = Path(self.td.name) / "api.log"
        self.api.write_text("")
        precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}]
        self.decisions = sd.plan(
            snapshot([row(1, precedent_key="k"), row(2)], precedent=precedent), now=NOW)
        self.approve = next(d for d in self.decisions if d.outcome == "approve")

    def _intents(self, db=None):
        db = db or sd.open_ledger(self.ledger)
        return db.execute("SELECT request_id, state, resolution FROM intents"
                          " ORDER BY request_id").fetchall()

    def _applied(self, db=None):
        db = db or sd.open_ledger(self.ledger)
        return [r[0] for r in db.execute(
            "SELECT request_id FROM applied WHERE outcome = 'approve'")]

    def _writes(self):
        return self.api.read_text().split()

    def _api_writer(self, d):
        with self.api.open("a") as fh:
            fh.write(d.request_id + "\n")

    def _api_reconciler(self, d, planned_at):
        return sd.LANDED if d.request_id in self._writes() else sd.NOT_LANDED

    def _crash(self, where):
        plan = Path(self.td.name) / "plan.jsonl"
        plan.write_bytes(sd.serialize(self.decisions))
        proc = subprocess.run(
            [sys.executable, "-c", CRASHING_APPLY, str(SCRIPTS), str(plan), self.ledger,
             str(self.api), where], capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, -signal.SIGKILL, proc.stderr)

    # ── the order ────────────────────────────────────────────────────────────
    def test_the_intent_is_on_disk_before_the_api_is_called(self):
        seen = []

        def writer(d):
            # a second connection: what another process would find if we died right here
            seen.append((self._intents(), self._applied()))

        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions, db, shards=1, write_pool=1, writer=writer)
        self.assertEqual(seen, [([(rid(1), "planned", None)], [])])
        self.assertEqual(self._intents(db), [(rid(1), "confirmed", "written")])
        self.assertEqual(self._applied(db), [rid(1)])

    def test_no_intent_no_api_call(self):
        """If the ledger cannot be told, the API is not either."""
        db = sd.open_ledger(self.ledger)
        db.execute("CREATE TRIGGER full_disk BEFORE INSERT ON intents"
                   " BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer)
        self.assertEqual(self._writes(), [])
        self.assertEqual(stats["errors"], 1)
        self.assertEqual(self._applied(db), [])

    def test_only_a_side_effect_gets_an_intent(self):
        """``ask`` writes nothing to the API, so there is nothing to be ahead of."""
        db = sd.open_ledger(self.ledger)
        sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer)
        self.assertEqual([r[0] for r in self._intents(db)], [rid(1)])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 2)

    # ── the crash ────────────────────────────────────────────────────────────
    def test_a_kill_between_the_write_and_the_confirm_is_reconciled_on_restart(self):
        self._crash("after-write")
        # what the dead process left: the API written, an intent, and no applied row
        self.assertEqual(self._writes(), [rid(1)])
        self.assertEqual(self._intents(), [(rid(1), "planned", None)])
        self.assertEqual(self._applied(), [])
        db = sd.open_ledger(self.ledger)
        before = sd.verify(self.decisions, db)
        self.assertFalse(before["ok"])
        self.assertEqual(before["unconfirmed"], [rid(1)])

        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=self._api_reconciler)
        # zero duplicates: the API was written once, and the ledger holds one row for it
        self.assertEqual(self._writes(), [rid(1)])
        self.assertEqual(self._applied(db), [rid(1)])
        # ...and the row is confirmed, as a reconciliation rather than a write we watched
        self.assertEqual(self._intents(db), [(rid(1), "confirmed", "reconciled")])
        self.assertEqual((stats["reconciled"], stats["errors"]), (1, 0))
        after = sd.verify(self.decisions, db)
        self.assertTrue(after["ok"], after)
        self.assertEqual(after["duplicate_request_ids"], [])
        self.assertEqual(after["unconfirmed"], [])
        # and a third run finds nothing left to do
        again = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=self._api_reconciler)
        self.assertEqual((again["applied"], again["skipped"]), (0, 2))
        self.assertEqual(self._writes(), [rid(1)])

    def test_a_kill_before_the_write_is_retried_on_restart(self):
        """The twin. Same open intent, but the API was never written - so 'landed' would
        be a lie, and the restart must make the write, exactly once."""
        self._crash("before-write")
        self.assertEqual(self._writes(), [])
        self.assertEqual(self._intents(), [(rid(1), "planned", None)])
        db = sd.open_ledger(self.ledger)
        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=self._api_reconciler)
        self.assertEqual(self._writes(), [rid(1)])
        self.assertEqual(self._intents(db), [(rid(1), "confirmed", "written")])
        self.assertEqual(stats["reconciled"], 0)
        self.assertTrue(sd.verify(self.decisions, db)["ok"])

    # ── what a restart must NOT do ───────────────────────────────────────────
    def _open_intent(self):
        db = sd.open_ledger(self.ledger)
        sd._record_intent(db, self.approve, 0, NOW)
        return db

    def test_a_request_decided_elsewhere_is_abandoned_and_never_written(self):
        db = self._open_intent()

        def elsewhere(d, planned_at):
            raise sd.Abandon("target_rejected")

        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=elsewhere)
        self.assertEqual(self._writes(), [])
        self.assertEqual(self._applied(db), [])
        self.assertEqual(self._intents(db), [(rid(1), "abandoned", "target_rejected")])
        self.assertEqual((stats["abandoned"], stats["errors"]), (1, 0))
        result = sd.verify(self.decisions, db)
        # known not to have happened, with why: reported, and not "missing"
        self.assertEqual(result["abandoned"],
                         [{"request_id": rid(1), "reason": "target_rejected"}])
        self.assertEqual(result["missing"], [])
        self.assertTrue(result["ok"], result)
        # an abandoned decision stays abandoned: no reconciler call, no write, next run
        again = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=lambda d, planned_at: self.fail("asked again"))
        self.assertEqual(again["abandoned"], 0)
        self.assertEqual(self._writes(), [])

    def test_an_unreadable_request_is_neither_confirmed_nor_written(self):
        db = self._open_intent()

        def unreadable(d, planned_at):
            raise sd.DrainError("admin API 503")

        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=unreadable)
        self.assertEqual(self._writes(), [])
        self.assertEqual(self._applied(db), [])
        self.assertEqual(self._intents(db), [(rid(1), "planned", None)])
        self.assertEqual((stats["unreconciled"], stats["errors"]), (1, 1))
        self.assertFalse(sd.verify(self.decisions, db)["ok"])

    def test_an_open_intent_with_no_reconciler_is_never_retried_blind(self):
        db = self._open_intent()
        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer)
        self.assertEqual(self._writes(), [])
        self.assertEqual(self._intents(db), [(rid(1), "planned", None)])
        self.assertEqual((stats["unreconciled"], stats["errors"]), (1, 1))

    def test_an_answer_that_is_not_a_verdict_settles_nothing(self):
        db = self._open_intent()
        stats = sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                         reconciler=lambda d, planned_at: "probably")
        self.assertEqual(self._writes(), [])
        self.assertEqual(self._intents(db), [(rid(1), "planned", None)])
        self.assertEqual(stats["unreconciled"], 1)

    def test_an_open_intent_is_never_marked_done_by_a_run_that_cannot_write(self):
        """No writer means no side effect - which, for a fresh row, is how chaos commits
        without touching the API. With an intent open it would record a write nobody
        made, so it is refused."""
        db = self._open_intent()
        stats = sd.apply(self.decisions, db, shards=1, write_pool=1,
                         reconciler=lambda d, planned_at: sd.NOT_LANDED)
        self.assertEqual(self._applied(db), [])
        self.assertEqual(self._intents(db), [(rid(1), "planned", None)])
        self.assertEqual(stats["unreconciled"], 1)

    def test_the_reconciler_is_given_the_time_the_intent_was_recorded(self):
        db = self._open_intent()
        seen = []

        def reconciler(d, planned_at):
            seen.append((d.decision_key, planned_at))
            return sd.LANDED

        sd.apply(self.decisions, db, shards=1, write_pool=1, writer=self._api_writer,
                 reconciler=reconciler)
        self.assertEqual(seen, [(self.approve.decision_key, "2026-11-11T12:00:00.000000Z")])

    # ── the ledger's own rules ───────────────────────────────────────────────
    def test_an_intent_is_resolved_once_and_never_rewritten(self):
        db = self._open_intent()
        key = self.approve.decision_key
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("DELETE FROM intents")
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("UPDATE intents SET planned_at = '2020-01-01T00:00:00Z'")
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("UPDATE intents SET request_id = ?", (rid(2),))
        # 'confirmed' is not a word a caller can write on its own: it needs the applied row
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("UPDATE intents SET state = 'confirmed', resolution = 'written',"
                       " resolved_at = 'now' WHERE decision_key = ?", (key,))
        self.assertTrue(sd._confirm_intent(db, self.approve, 0, NOW, sd.WRITTEN))
        for state, resolution in (("abandoned", "target_rejected"), ("planned", None),
                                  ("confirmed", "reconciled")):
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE intents SET state = ?, resolution = ?, resolved_at = ?"
                           " WHERE decision_key = ?",
                           (state, resolution, None if state == "planned" else "now", key))
        self.assertEqual(self._intents(db), [(rid(1), "confirmed", "written")])

    def test_the_confirm_and_the_applied_row_are_one_transaction(self):
        """A confirm that cannot finish leaves NEITHER half behind."""
        db = self._open_intent()
        db.execute("CREATE TRIGGER boom BEFORE UPDATE ON intents"
                   " BEGIN SELECT RAISE(ABORT, 'boom'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            sd._confirm_intent(db, self.approve, 0, NOW, sd.WRITTEN)
        self.assertEqual(self._applied(db), [])
        self.assertEqual(self._intents(db), [(rid(1), "planned", None)])

    def test_a_write_with_no_intent_is_not_recorded(self):
        db = sd.open_ledger(self.ledger)
        with self.assertRaises(sd.DrainError):
            sd._confirm_intent(db, self.approve, 0, NOW, sd.WRITTEN)
        self.assertEqual(self._applied(db), [])

    def test_an_older_ledger_gains_the_intents_table_on_open(self):
        """The ledger on node-8 predates intents; opening it must add them, not fail."""
        raw = sqlite3.connect(self.ledger)
        raw.executescript(sd.LEDGER_SCHEMA.split("CREATE TABLE IF NOT EXISTS intents")[0])
        raw.execute("INSERT INTO applied VALUES ('k', 'r', 'ask', 'ask', 'x', 0, 't')")
        raw.commit()
        raw.close()
        db = sd.open_ledger(self.ledger)
        self.assertEqual(self._intents(db), [])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 1)


TRACK = "0a1b2c3d-0000-4000-8000-00000000abcd"
#: ``verificationData.duplicate_of`` exactly as core carries it on every pending row that
#: has one (856 of 96,703 on 2026-11-11): a map from "<track uuid>|<role>" to the 24-hex
#: id of the credit already on the profile. Never a request id.
PROFILE_CREDIT_MAP = {f"{TRACK}|composer": "65f0c2a4e1b7d9a3c5e8f012",
                      f"{TRACK}|producer": "65f0c2a4e1b7d9a3c5e8f013"}


class RealDataShapeTests(unittest.TestCase):
    """The two shapes the live snapshot has and the fixtures did not (readout r1, 15:14Z).

    Every fixture in this file wrote ``duplicate_of`` as a request id and keyed a proof
    verdict by request id. Production does neither: ``duplicate_of`` is a map of profile
    credits, and the proof store keys a verdict by claim, ``<request>#<Role>``. The first
    crashed the plan on 856 rows. The second made the proof rule match nothing, so 10,559
    pending requests with a document on file read as "no proof received".
    """

    def _proof_store(self, td, rows):
        path = str(Path(td) / "proof.sqlite")
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO verdicts (proof_id, request_id, verdict, created_at)"
                       " VALUES (?,?,?,?)", rows)
        db.commit()
        db.close()
        return path

    def _plan_from_replica(self, td, pending, proof_rows=(), decided=()):
        """The real path: replica rows -> snapshot JSONL -> ``plan --snapshot``."""
        proofs = self._proof_store(td, list(proof_rows))

        def q(sql):
            return list(decided) if "status IN ('approved', 'rejected')" in sql else list(pending)

        rows = sd.replica_snapshot_rows(q, proof_store_path=proofs)
        path = str(Path(td) / "snap.jsonl")
        with open(path, "w") as fh:
            for r in rows:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
        return sd.plan(sd._build_snapshot(_args(snapshot=path)), now=NOW)

    def _pending(self, n, roles="{Composer,Producer}", vd=None, user=None):
        return (rid(n), str(user or 1000 + n), f"p{n}", "user_verification_needed",
                "2026-11-01T00:00:00Z", json.dumps(vd or {}), "{}", TRACK, roles)

    # ── duplicate_of is a map ────────────────────────────────────────────────
    def test_a_duplicate_of_map_does_not_crash_the_plan(self):
        with tempfile.TemporaryDirectory() as td:
            decisions = self._plan_from_replica(
                td, [self._pending(1, vd={"duplicate_of": PROFILE_CREDIT_MAP}), self._pending(2)])
        by_id = {d.request_id: d for d in decisions}
        d = by_id[rid(1)]
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("duplicate", sd.UNMATCHED, "already_on_profile"))
        self.assertIsNone(d.duplicate_of)
        # the row beside it is untouched by its neighbour
        self.assertEqual(by_id[rid(2)].outcome, "ask")

    def test_an_already_on_profile_row_is_neither_written_nor_asked(self):
        from credit_review import need_asks

        decisions = sd.plan(snapshot([row(1, duplicate_of=PROFILE_CREDIT_MAP), row(2)]), now=NOW)
        calls = []
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            stats = sd.apply(decisions, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            self.assertEqual(calls, [])
            self.assertEqual(stats["unmatched"], 1)
            self.assertEqual([r[0] for r in db.execute("SELECT request_id FROM applied")], [rid(2)])
            self.assertTrue(sd.verify(decisions, db)["ok"])
            plan_path = Path(td) / "plan.jsonl"
            plan_path.write_bytes(sd.serialize(decisions))
            # the one reviewed ask path is handed row 2 and never row 1
            self.assertEqual(need_asks.drain_asks(str(plan_path)), {(1002, rid(2))})

    def test_it_keeps_rank_one_and_does_not_slide_to_a_lower_rule(self):
        """A duplicate fact outranks precedent and proof whether or not it can be closed:
        a row core says is already on the profile is not approved on a precedent here."""
        db = snapshot([row(1, duplicate_of=PROFILE_CREDIT_MAP, precedent_key="k",
                           proof_verdict="approve", proof_id="a" * 64)],
                      precedent=[{"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}])
        d = sd.plan(db, now=NOW)[0]
        self.assertEqual((d.rule, d.outcome), ("duplicate", sd.UNMATCHED))

    def test_classify_duplicate(self):
        self.assertEqual(sd.classify_duplicate(rid(9)), (rid(9), "request"))
        self.assertEqual(sd.classify_duplicate(PROFILE_CREDIT_MAP), (None, "profile_credit"))
        for nothing in (None, "", {}, []):
            self.assertEqual(sd.classify_duplicate(nothing), (None, None), nothing)
        for odd in ([rid(9)], 7, True):
            self.assertEqual(sd.classify_duplicate(odd), (None, "other"), odd)

    def test_no_shape_of_duplicate_of_can_crash_the_load(self):
        shapes = [PROFILE_CREDIT_MAP, [rid(9)], 7, {"a": {"b": [1]}}, {}, [], "", None, rid(9)]
        db = snapshot([row(i + 1, duplicate_of=v) for i, v in enumerate(shapes)])
        got = {d.request_id: (d.rule, d.outcome, d.reason_code) for d in sd.plan(db, now=NOW)}
        self.assertEqual(got[rid(1)], ("duplicate", sd.UNMATCHED, "already_on_profile"))
        self.assertEqual(got[rid(2)], ("duplicate", sd.UNMATCHED, "unmatched_duplicate"))
        self.assertEqual(got[rid(3)], ("duplicate", sd.UNMATCHED, "unmatched_duplicate"))
        self.assertEqual(got[rid(4)], ("duplicate", sd.UNMATCHED, "already_on_profile"))
        for empty in (5, 6, 7, 8):          # no duplicate fact at all: an ordinary ask
            self.assertEqual(got[rid(empty)], ("ask", "ask", "no_rule_matched"), empty)
        self.assertEqual(got[rid(9)], ("duplicate", sd.UNMATCHED, "unmatched_duplicate"))

    def test_a_snapshot_database_from_before_the_column_still_opens(self):
        with tempfile.TemporaryDirectory() as td:
            path = str(Path(td) / "snap.sqlite")
            old = sqlite3.connect(path)
            old.executescript(sd.SNAPSHOT_SCHEMA.replace("  duplicate_kind    TEXT,\n", ""))
            self.assertNotIn("duplicate_kind",
                             {r[1] for r in old.execute("PRAGMA table_info(requests)")})
            old.close()
            db = sd.open_snapshot(path)
            sd.load_snapshot(db, [row(1, duplicate_of=PROFILE_CREDIT_MAP)])
            self.assertEqual(sd.plan(db, now=NOW)[0].reason_code, "already_on_profile")

    # ── the proof store keys a verdict by claim ──────────────────────────────
    def test_a_claim_keyed_verdict_reaches_its_request(self):
        """The test the old suite did not have: the store's own key shape, end to end."""
        with tempfile.TemporaryDirectory() as td:
            decisions = self._plan_from_replica(td, [self._pending(1)], [
                ("a" * 64, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z"),
                ("a" * 64, f"{rid(1)}#Producer", "GENUINE", "2026-11-02T00:00:00Z")])
        d = decisions[0]
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("proof_verdict", "approve", "proof_verdict_approve"))
        self.assertEqual(d.evidence_anchor, "a" * 64)

    def _fact(self, rows, roles=("Composer", "Producer")):
        with tempfile.TemporaryDirectory() as td:
            claims = sd.proof_claims(self._proof_store(td, rows))
        return sd.proof_fact(claims.get(rid(1)), list(roles))

    def test_every_claimed_role_must_be_approved_on_one_proof(self):
        ok = [("a" * 64, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z"),
              ("a" * 64, f"{rid(1)}#Producer", "VERIFIED", "2026-11-02T00:00:00Z")]
        self.assertEqual(self._fact(ok)["proof_verdict"], "approve")
        self.assertEqual(self._fact(ok)["proof_id"], "a" * 64)
        cases = {
            "one role is still soft": [ok[0], ("a" * 64, f"{rid(1)}#Producer", "SUSPECT",
                                               "2026-11-02T00:00:00Z")],
            "a claimed role has no verdict": [ok[0]],
            "the roles rest on different proofs": [ok[0], ("b" * 64, f"{rid(1)}#Producer",
                                                           "GENUINE", "2026-11-02T00:00:00Z")],
            "a role on file that is no longer claimed is soft": ok + [
                ("a" * 64, f"{rid(1)}#Mixing", "PLAUSIBLE", "2026-11-02T00:00:00Z")],
            "a newer soft verdict cleared the approval": ok + [
                ("c" * 64, f"{rid(1)}#Producer", "PLAUSIBLE", "2026-11-03T00:00:00Z")],
        }
        for name, rows in cases.items():
            with self.subTest(case=name):
                fact = self._fact(rows)
                self.assertIsNone(fact["proof_verdict"])
                self.assertIsNone(fact["proof_id"], "a soft verdict is never an anchor")
                # ...but the document IS on file, whatever its verdict
                self.assertTrue(fact["proof_received_at"])

    def test_one_refused_role_refuses_the_request(self):
        fact = self._fact([
            ("a" * 64, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z"),
            ("b" * 64, f"{rid(1)}#Producer", "FORGED_LIKELY", "2026-11-02T00:00:00Z")])
        self.assertEqual((fact["proof_verdict"], fact["proof_id"]), ("refuse", "b" * 64))

    def test_role_case_and_spacing_do_not_decide_a_verdict(self):
        rows = [("a" * 64, f"{rid(1)}#composer", "GENUINE", "2026-11-02T00:00:00Z"),
                ("a" * 64, f"{rid(1)}# Producer ", "GENUINE", "2026-11-02T00:00:00Z")]
        self.assertEqual(self._fact(rows, roles=("COMPOSER", "producer"))["proof_verdict"],
                         "approve")

    def test_a_request_with_no_roles_is_the_stores_unknown_claim(self):
        rows = [("a" * 64, f"{rid(1)}#unknown", "GENUINE", "2026-11-02T00:00:00Z")]
        self.assertEqual(self._fact(rows, roles=())["proof_verdict"], "approve")
        self.assertIsNone(self._fact(rows, roles=("Composer",))["proof_verdict"])

    def test_a_whole_request_verdict_does_not_stand_in_for_a_role(self):
        """A verdict keyed by the bare request id names no role, so it cannot be the
        verdict for whatever the request claims: that would be the one row that approves
        any role set. The gate applies the same rule against the live request, so the
        planner must not plan an approve the gate refuses (QA review 6 of hydra#1883)."""
        bare = [("a" * 64, rid(1), "GENUINE", "2026-11-02T00:00:00Z")]
        self.assertIsNone(self._fact(bare, roles=("Composer",))["proof_verdict"])
        self.assertIsNone(self._fact(bare, roles=())["proof_verdict"])
        self.assertTrue(self._fact(bare, roles=("Composer",))["proof_received_at"])
        # beside a real claim it still does not cover the role that has none...
        mixed = bare + [("a" * 64, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z")]
        self.assertIsNone(self._fact(mixed)["proof_verdict"])
        # ...and it is still held to the approve rule where every role IS covered
        self.assertEqual(self._fact(mixed, roles=("Composer",))["proof_verdict"], "approve")
        soft = [("a" * 64, rid(1), "SUSPECT", "2026-11-02T00:00:00Z"), mixed[1]]
        self.assertIsNone(self._fact(soft, roles=("Composer",))["proof_verdict"])

    def test_another_requests_claims_are_not_this_requests(self):
        with tempfile.TemporaryDirectory() as td:
            claims = sd.proof_claims(self._proof_store(td, [
                ("a" * 64, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z"),
                ("b" * 64, f"{rid(2)}#Composer", "INCONSISTENT", "2026-11-02T00:00:00Z")]))
        self.assertEqual(set(claims), {rid(1), rid(2)})
        self.assertEqual(sd.proof_fact(claims[rid(1)], ["Composer"])["proof_verdict"], "approve")
        self.assertEqual(sd.proof_fact(claims[rid(2)], ["Composer"])["proof_verdict"], "refuse")
        self.assertEqual(sd.proof_fact(claims.get(rid(3)), ["Composer"]), {})

    def test_a_document_on_file_is_never_expired_no_proof(self):
        """The harm the wrong key did quietly: asked 40 days ago, answered with a document
        the analyzer has not decided on. Read as "no proof received", this row was headed
        for ``expired_no_proof`` - a row saying the customer sent nothing."""
        ledger_rows = [("verify-live", "sent", "1001", "2026-10-01T00:00:00Z", json.dumps([rid(1)]))]
        with tempfile.TemporaryDirectory() as td:
            ledger = str(Path(td) / "ledger.sqlite")
            ldb = sqlite3.connect(ledger)
            ldb.execute("CREATE TABLE verify_messages (campaign TEXT, status TEXT, account_id TEXT,"
                        " sent_at TEXT, request_ids_json TEXT NOT NULL)")
            ldb.executemany("INSERT INTO verify_messages VALUES (?,?,?,?,?)", ledger_rows)
            ldb.commit()
            ldb.close()
            for rows, expected in (
                    ([], ("expired", "cannot_confirm", "expired_no_proof")),
                    ([("a" * 64, f"{rid(1)}#Composer", "SUSPECT", "2026-10-20T00:00:00Z"),
                      ("a" * 64, f"{rid(1)}#Producer", "SUSPECT", "2026-10-20T00:00:00Z")],
                     ("ask", "ask", "proof_on_file_undecided"))):
                with self.subTest(on_file=bool(rows)):
                    proofs = self._proof_store(tempfile.mkdtemp(dir=td), rows)
                    snap = sd.snapshot_from_replica(lambda sql: [self._pending(1)],
                                                    ledger_path=ledger, proof_store_path=proofs)
                    d = sd.plan(snapshot(snap), now=NOW)[0]
                    self.assertEqual((d.rule, d.outcome, d.reason_code), expected)

    def test_the_plan_summary_counts_reasons(self):
        with tempfile.TemporaryDirectory() as td:
            snap = Path(td) / "snap.jsonl"
            rows = [row(1, duplicate_of=PROFILE_CREDIT_MAP), row(2),
                    row(3, proof_received_at="2026-11-02T00:00:00Z")]
            snap.write_text("".join(json.dumps(r) + "\n" for r in rows))
            proc = subprocess.run(cli("plan", "--snapshot", str(snap), "--now", "2026-11-11T12:00:00Z"),
                                  capture_output=True, text=True, cwd=SCRIPTS, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertEqual(summary["by_reason"], {"unmatched/already_on_profile": 1,
                                                "ask/no_rule_matched": 1,
                                                "ask/proof_on_file_undecided": 1})
        self.assertEqual(summary["unmatched"], 1)


class FailureClassTests(unittest.TestCase):
    """A failed write names its cause, and a cause that is the RUN's stops the run.

    2026-11-11: the pass recorded 3,326 approve intents and landed none. Every one failed
    the same way - ``apply`` was started from a shell that did not carry the admin env, so
    the wrapper died in ``check_env`` before its gate ran - and the summary said only
    ``errors``. Nothing in the code told one cause from 3,326 different ones, or a cause
    that the next row would repeat from one it would not.
    """

    WRAPPERS = ("skills-all/muso-ops-admin/scripts/muso-admin-api.sh",
                "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh")

    def test_the_wrappers_own_refusals_are_told_apart(self):
        token = "scale_drain: /etc/hydra/scale-drain.token is missing - refusing (an approval needs the root-only token)"
        cases = [
            ("ERROR: MUSO_API_URL not set", ("admin_env_missing", True)),
            ("ERROR: MUSO_ADMIN_PASSWORD not set", ("admin_env_missing", True)),
            ("ERROR: admin identity 'fable': /etc/x/fable.env is missing or unreadable (no fallback)",
             ("admin_env_missing", True)),
            ("ERROR: MUSO_ADMIN_IDENTITY 'scale-drain' is not a known automation identity "
             "(credit-decider, uvn-cron, fable)", ("admin_env_missing", True)),
            ("scale_drain: /etc/hydra/scale-drain.disabled is present - refusing",
             ("drain_kill_file", True)),
            (token, ("drain_token", True)),
            ("scale_drain: SCALE_DRAIN_TOKEN does not match /etc/hydra/scale-drain.token - refusing",
             ("drain_token", True)),
            ("scale_drain: verification-scale-drain is not approved in /x/registry.json - refusing",
             ("drain_registry", True)),
            ("scale_drain: anchor verification failed: anchor is not approved",
             ("anchor_unverified", False)),
            ("scale_drain: exactly one requestId per call (one digest carries one anchor) - refusing",
             ("drain_gate_refused", False)),
            ("credit_approve_gate: --evidence-excerpt is required for autonomous approves.",
             ("approve_gate_refused", False)),
            ("Segmentation fault", ("wrapper_failed", False)),
            ("", ("wrapper_failed", False)),
        ]
        for text, want in cases:
            with self.subTest(text=text[:50]):
                self.assertEqual(sd.classify_refusal(text), want)
        # A refused drain predicate falls through to the generic gate, which adds a second
        # line of its own. The drain's reason is the cause; the second line is not.
        both = token + "\ncredit_approve_gate: no active openclaw session log (mtime <10 min) found; refusing autonomous approve."
        self.assertEqual(sd.classify_refusal(both), ("drain_token", True))

    def test_an_unknown_identity_is_classified_from_what_the_wrapper_prints(self):
        """The drain's writer is the workspace wrapper. Run it with a plausible typo for
        an identity and classify its own refusal, so a message that changes shape cannot
        silently fall back to a row-level cause."""
        wrapper = SCRIPTS.parent / "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
        env = {k: v for k, v in os.environ.items()
               if k not in sd.ADMIN_ENV_REQUIRED and k != sd.ADMIN_IDENTITY_ENV}
        env.update({"MUSO_API_URL": "https://example.invalid",
                    sd.ADMIN_IDENTITY_ENV: "scale-drain"})
        proc = subprocess.run(["bash", str(wrapper), "call", "PUT",
                               "/admin/credit-requests", "{}"],
                              capture_output=True, text=True, env=env, check=False)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(sd.classify_refusal(proc.stderr + proc.stdout),
                         ("admin_env_missing", True))

    def test_the_env_the_preflight_asks_for_is_the_env_the_wrapper_dies_without(self):
        """``ADMIN_ENV_REQUIRED`` is a copy of the wrapper's ``check_env``. Run the real
        wrapper with each variable unset and hold the preflight to what it actually
        refuses, in both copies, or a variable the wrapper starts requiring is one the
        preflight waves through."""
        base = {"MUSO_API_URL": "https://example.invalid", "MUSO_ADMIN_EMAIL": "a@b.c",
                "MUSO_ADMIN_PASSWORD": "x"}
        for wrapper in self.WRAPPERS:
            for name in sd.ADMIN_ENV_REQUIRED:
                with self.subTest(wrapper=wrapper, name=name):
                    env = {k: v for k, v in os.environ.items()
                           if k not in sd.ADMIN_ENV_REQUIRED and k != sd.ADMIN_IDENTITY_ENV}
                    env.update({k: v for k, v in base.items() if k != name})
                    proc = subprocess.run(["bash", str(SCRIPTS.parent / wrapper), "login"],
                                          capture_output=True, text=True, env=env, check=False)
                    self.assertNotEqual(proc.returncode, 0, proc.stdout)
                    self.assertIn(f"{name} not set", proc.stdout + proc.stderr)
                    problems = self._preflight(env)
                    self.assertEqual([c for c, _ in problems], ["admin_env_missing"])
                    self.assertIn(name, problems[0][1])

    def _preflight(self, env, *, token=True, kill=False, identity=True, approves=True):
        td = Path(tempfile.mkdtemp())
        script = td / "wrapper.sh"
        script.write_text("#!/bin/sh\n")
        token_file = td / "scale-drain.token"
        if token:
            token_file.write_text("s3cret\n")
        kill_file = td / "scale-drain.disabled"
        if kill:
            kill_file.write_text("")
        if identity:
            (td / "scale-drain.env").write_text(
                "MUSO_ADMIN_EMAIL=agent-scale-drain@example.com\nMUSO_ADMIN_PASSWORD=x\n")
        env = {**env, sd.ADMIN_IDENTITY_DIR_ENV: str(td)}
        return sd.admin_preflight(str(script), token_file=str(token_file),
                                  kill_file=str(kill_file), environ=env, approves=approves)

    GOOD_ENV = {"MUSO_API_URL": "https://example.invalid", "MUSO_ADMIN_EMAIL": "a@b.c",
                "MUSO_ADMIN_PASSWORD": "x"}

    def test_a_process_that_can_write_passes_the_preflight(self):
        self.assertEqual(self._preflight(dict(self.GOOD_ENV)), [])

    def test_a_bare_shell_fails_the_preflight_once_and_by_name(self):
        """The 2026-11-11 shell: no admin env at all."""
        problems = self._preflight({"PATH": "/usr/bin"})
        self.assertEqual([c for c, _ in problems], ["admin_env_missing"])
        for name in sd.ADMIN_ENV_REQUIRED:
            self.assertIn(name, problems[0][1])

    def test_a_blank_value_is_a_missing_value(self):
        problems = self._preflight({**self.GOOD_ENV, "MUSO_API_URL": "  "})
        self.assertEqual([c for c, _ in problems], ["admin_env_missing"])
        self.assertIn("MUSO_API_URL", problems[0][1])
        self.assertNotIn("MUSO_ADMIN_EMAIL", problems[0][1])

    def test_a_named_identity_does_not_supply_the_admin_env(self):
        """The wrapper loads that account for ``login|call|upload`` only. The verifier's
        anchor read and the read-back go through ``call-batch``, which loads no identity
        and dies in its own env check, so the admin env is still needed - otherwise the
        preflight passes a run that records intents and then fails every row."""
        env = {"MUSO_API_URL": "https://example.invalid", "MUSO_ADMIN_IDENTITY": "fable"}
        problems = self._preflight(env)
        self.assertEqual([c for c, _ in problems], ["admin_env_missing"])
        for name in ("MUSO_ADMIN_EMAIL", "MUSO_ADMIN_PASSWORD"):
            self.assertIn(name, problems[0][1])
        self.assertNotIn("MUSO_API_URL", problems[0][1])
        partial = self._preflight({**env, "MUSO_ADMIN_EMAIL": "a@b.c"})
        self.assertEqual([c for c, _ in partial], ["admin_env_missing"])
        self.assertIn("MUSO_ADMIN_PASSWORD", partial[0][1])
        self.assertEqual(self._preflight({"MUSO_ADMIN_IDENTITY": "fable"})[0][0],
                         "admin_env_missing")

    def test_no_token_an_empty_token_and_a_redirected_token_all_fail(self):
        self.assertEqual([c for c, _ in self._preflight(dict(self.GOOD_ENV), token=False)],
                         ["drain_token"])
        td = Path(tempfile.mkdtemp())
        (td / "w.sh").write_text("")
        (td / "t").write_text("\n")
        problems = sd.admin_preflight(str(td / "w.sh"), token_file=str(td / "t"),
                                      kill_file=str(td / "nope"), environ=dict(self.GOOD_ENV),
                                      approves=False)
        self.assertEqual([c for c, _ in problems], ["drain_token"])
        problems = self._preflight({**self.GOOD_ENV, sd.DRAIN_TOKEN_FILE_ENV: "/tmp/mine"})
        self.assertEqual([c for c, _ in problems], ["drain_token"])

    def test_a_held_drain_fails_the_preflight(self):
        self.assertEqual([c for c, _ in self._preflight(dict(self.GOOD_ENV), kill=True)],
                         ["drain_kill_file"])

    def test_a_missing_wrapper_fails_the_preflight(self):
        problems = sd.admin_preflight("/nonexistent/muso-admin-api.sh",
                                      token_file="/nonexistent/t", kill_file="/nonexistent/k",
                                      environ=dict(self.GOOD_ENV), approves=False)
        self.assertEqual([c for c, _ in problems], ["admin_script_missing", "drain_token"])

    def test_an_approve_without_the_drains_own_identity_file_fails_the_preflight(self):
        """node-8 on 2026-11-13: credit-decider.env, fable.env and uvn-cron.env exist and
        scale-drain.env does not. The wrapper refuses that before any request, for every
        approve alike, so it is asked once. A plan with no approve left makes no write
        and needs no identity file."""
        problems = self._preflight(dict(self.GOOD_ENV), identity=False)
        self.assertEqual([c for c, _ in problems], ["admin_env_missing"])
        self.assertIn("scale-drain.env", problems[0][1])
        self.assertIn("no fallback account", problems[0][1])
        self.assertEqual(self._preflight(dict(self.GOOD_ENV), identity=False, approves=False), [])

    def test_the_identity_file_the_preflight_names_is_the_one_the_wrapper_refuses(self):
        """Held to the real wrapper's words, so a renamed directory or identity cannot
        leave the preflight passing a run whose every approve dies in the wrapper."""
        td = Path(tempfile.mkdtemp())
        # only the operations copy loads an identity; the skills-all copy has no loader
        (operations,) = [w for w in self.WRAPPERS if w.startswith("workspaces/operations/")]
        env = {**self.GOOD_ENV, "PATH": os.environ["PATH"], "HOME": str(td),
               "MUSO_ADMIN_IDENTITY": sd.ADMIN_IDENTITY, sd.ADMIN_IDENTITY_DIR_ENV: str(td)}
        proc = subprocess.run(["bash", str(SCRIPTS.parent / operations), "login"],
                              capture_output=True, text=True, env=env, check=False)
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        said = proc.stdout + proc.stderr
        self.assertIn(f"admin identity '{sd.ADMIN_IDENTITY}': {td}/scale-drain.env is missing", said)
        self.assertEqual(sd.classify_refusal(said), ("admin_env_missing", True))

    # -- apply(): what a classified failure does to the run -------------------------

    def _decisions(self, n):
        return [sd.Decision(rid(i), "precedent", "approve", "precedent_match",
                            sd.decision_key(rid(i), "precedent", "approve"),
                            evidence_anchor=rid(900 + i), profile_id=rid(7))
                for i in range(1, n + 1)]

    def _ledger(self):
        return sd.open_ledger(str(Path(tempfile.mkdtemp()) / "ledger.sqlite"))

    def test_a_run_level_failure_stops_the_run_at_the_first_row(self):
        """3,326 rows that would each fail for the same reason: one write is tried, one
        intent is recorded, and the summary says why it stopped."""
        calls = []

        def writer(d):
            calls.append(d.request_id)
            raise sd.DrainConfigError(f"{d.request_id}: wrapper rc=1: ERROR: MUSO_API_URL not set",
                                      "admin_env_missing")

        db = self._ledger()
        stats = sd.apply(self._decisions(40), db, shards=1, write_pool=1, writer=writer)
        self.assertEqual(calls, [rid(1)])
        self.assertTrue(stats["stopped"])
        self.assertEqual(stats["error_classes"], {"admin_env_missing": 1})
        self.assertEqual(stats["errors"], 1)
        self.assertTrue(stats["stopped_reason"].startswith("admin_env_missing: "), stats)
        self.assertIn("MUSO_API_URL not set", stats["stopped_reason"])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 1)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)

    def test_a_run_level_failure_stops_every_worker_not_only_the_one_that_met_it(self):
        calls = []

        def writer(d):
            calls.append(d.request_id)
            raise sd.DrainConfigError("no token", "drain_token")

        stats = sd.apply(self._decisions(60), self._ledger(), shards=6, write_pool=6,
                         writer=writer)
        self.assertTrue(stats["stopped"])
        # at most one in-flight write per worker when the first failure lands
        self.assertLessEqual(len(calls), 6)
        self.assertEqual(stats["error_classes"], {"drain_token": len(calls)})

    def test_a_row_level_failure_is_counted_by_cause_and_does_not_stop_the_run(self):
        """core refusing one row says nothing about the next: the run goes on, and the
        summary carries the cause 3 times instead of the word ``errors``."""
        def writer(d):
            if d.request_id in (rid(2), rid(4), rid(5)):
                raise sd.DrainRefusedByCore(f"{d.request_id}: core refused")
            if d.request_id == rid(3):
                raise sd.DrainWriteError(f"{d.request_id}: wrapper reported HTTP 503", "http_error")
            if d.request_id == rid(6):
                raise RuntimeError("not one of ours")

        db = self._ledger()
        stats = sd.apply(self._decisions(7), db, shards=1, write_pool=1, writer=writer)
        self.assertFalse(stats["stopped"])
        self.assertNotIn("stopped_reason", stats)
        self.assertEqual(stats["error_classes"], {"core_automation_not_registered": 3,
                                                  "http_error": 1, "writer_exception": 1})
        self.assertEqual((stats["errors"], stats["applied"]), (5, 2))
        self.assertEqual(sum(stats["error_classes"].values()), stats["errors"])

    def test_an_unreadable_intent_says_why_instead_of_counting_in_silence(self):
        """The resumed 11-11 pass: every open intent failed its read for one reason, and
        the run printed nothing. The cause now reaches stderr and the summary, and a
        cause that is the run's stops it."""
        import contextlib
        import io
        decisions = self._decisions(5)
        db = self._ledger()
        for d in decisions:
            sd._record_intent(db, d, 0, NOW)
        seen = []

        def reconciler(d, planned_at):
            seen.append(d.request_id)
            raise sd.DrainConfigError(
                f"{d.request_id}: could not reconcile: BatchAdminError: call-batch failed "
                "rc=1: ERROR: MUSO_API_URL not set", "admin_env_missing")

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            stats = sd.apply(decisions, db, shards=1, write_pool=1,
                             writer=lambda d: self.fail("wrote without a read"),
                             reconciler=reconciler)
        self.assertEqual(seen, [rid(1)])
        self.assertIn(f"RECONCILEFAIL {rid(1)}: DrainConfigError:", err.getvalue())
        self.assertIn("MUSO_API_URL not set", err.getvalue())
        self.assertEqual(stats["error_classes"], {"admin_env_missing": 1})
        self.assertEqual((stats["unreconciled"], stats["stopped"]), (1, True))
        self.assertEqual(db.execute(
            "SELECT COUNT(*) FROM intents WHERE state = 'planned'").fetchone()[0], 5)

    def test_every_error_is_counted_under_exactly_one_cause(self):
        """``error_classes`` is a breakdown of ``errors``: an error path that forgets its
        cause would make the two disagree. Driven through the real ``apply`` on each
        failure path it has."""
        def row_level(d):
            raise sd.DrainWriteError(f"{d.request_id}: wrapper reported HTTP 503", "http_error")

        def run_level(d):
            raise sd.DrainConfigError(
                f"{d.request_id}: wrapper rc=1: ERROR: MUSO_API_URL not set", "admin_env_missing")

        def unclassified(d):
            raise RuntimeError("not one of ours")

        for name, writer in (("row_level", row_level), ("run_level", run_level),
                             ("unclassified", unclassified)):
            with self.subTest(name):
                stats = sd.apply(self._decisions(4), self._ledger(), shards=1, write_pool=1,
                                 writer=writer)
                self.assertGreater(stats["errors"], 0)
                self.assertEqual(sum(stats["error_classes"].values()), stats["errors"])

        # An unreadable intent is an error too, and it is counted under its own cause.
        decisions = self._decisions(3)
        db = self._ledger()
        for d in decisions:
            sd._record_intent(db, d, 0, NOW)

        def reconciler(d, planned_at):
            raise sd.DrainConfigError(f"{d.request_id}: could not reconcile", "admin_env_missing")

        calls = []
        stats = sd.apply(decisions, db, shards=1, write_pool=1,
                         writer=calls.append, reconciler=reconciler)
        self.assertEqual(calls, [])
        self.assertGreater(stats["errors"], 0)
        self.assertEqual(sum(stats["error_classes"].values()), stats["errors"])

        # A ledger that cannot record the intent is an error, not a silent skip.
        db = self._ledger()
        db.execute("DROP TABLE intents")
        calls = []
        stats = sd.apply(self._decisions(2), db, shards=1, write_pool=1,
                         writer=calls.append)
        self.assertEqual(calls, [])
        self.assertGreater(stats["errors"], 0)
        self.assertEqual(sum(stats["error_classes"].values()), stats["errors"])


class _FakeApi:
    """A `curl` on PATH that answers as core-backend would, and records every request.

    This is the same seam ``muso-admin-api-call-batch.bats`` uses. It replaces the NETWORK
    and nothing else: the wrapper, its gate chain, the verifier and the batch client are
    the real files at their real paths.
    """

    def __init__(self, root: Path):
        self.root = root
        self.log = root / "curl.log"
        self.items = root / "items.json"
        self.put_body = root / "put.json"
        (root / "bin").mkdir()
        stub = root / "bin/curl"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'printf \'%s\\n\' "$*" >> "$FAKE_API_LOG"\n'
            'case "$*" in\n'
            '    *"/admin/user/login"*) printf \'{"data":{"authentication":{"accessToken":"t"}}}\' ;;\n'
            '    *"-X GET"*"/admin/credit-requests?"*)\n'
            '        if [ -f "$FAKE_API_ITEMS.after-put" ] && grep -q -- "-X PUT" "$FAKE_API_LOG"; then\n'
            '            cat "$FAKE_API_ITEMS.after-put"\n'
            '        else cat "$FAKE_API_ITEMS"; fi; printf \'\\n200\' ;;\n'
            '    *"-X PUT"*) cat "$FAKE_API_PUT"; printf \'\\n%s\' "${FAKE_API_PUT_STATUS:-200}" ;;\n'
            '    *) printf \'{"error":"unexpected request"}\\n500\' ;;\n'
            "esac\n")
        stub.chmod(0o755)
        (root / "codex-health.sh").write_text("codex_health_gate() { return 0; }\n")
        (root / "token-cache").write_text(f"{int(time.time())}\ndummy-token\n")
        # The approve signs in as the drain's own account (MUSO_ADMIN_IDENTITY=scale-drain).
        (root / "identities").mkdir()
        (root / "identities/scale-drain.env").write_text(
            "MUSO_ADMIN_EMAIL=agent-scale-drain@example.com\nMUSO_ADMIN_PASSWORD=unused\n")

    def serve(self, items: list[dict], updated: list[str],
              after_put: list[dict] | None = None) -> None:
        """``after_put`` is what a GET answers once a PUT has been made: the row as core
        holds it after the write. Without it the GET keeps answering ``items``, which is
        a core that said 200 and changed nothing."""
        self.items.write_text(json.dumps({"data": {"items": items}}))
        after = Path(f"{self.items}.after-put")
        if after_put is None:
            after.unlink(missing_ok=True)
        else:
            after.write_text(json.dumps({"data": {"items": after_put}}))
        self.put_body.write_text(json.dumps({"data": {"updatedIds": updated}}))
        self.log.write_text("")

    def requests(self, verb: str) -> list[str]:
        return [ln for ln in self.log.read_text().splitlines() if f"-X {verb}" in ln]

    def env(self, registry: Path = REGISTRY) -> dict[str, str]:
        """``registry`` must be the registry of the tree the wrapper under test lives in:
        the gate pins the registry to its own tree and REFUSES a variable naming another.
        It is named at all only because the operations wrapper defaults the variable to
        ``/opt/hydra/...`` at file scope, which is not this checkout."""
        return {
            "PATH": f"{self.root / 'bin'}:/usr/local/bin:/usr/bin:/bin",
            "HOME": str(self.root),
            "FAKE_API_LOG": str(self.log),
            "FAKE_API_ITEMS": str(self.items),
            "FAKE_API_PUT": str(self.put_body),
            "MUSO_API_URL": "https://example.invalid",
            "MUSO_ADMIN_EMAIL": "test@example.com",
            "MUSO_ADMIN_PASSWORD": "unused",
            "MUSO_OPS_STATE_DIR": str(self.root / "state"),
            "OPS_RUNLOG_DIR": str(self.root / "runlogs"),
            "CV_RESULTS_PATH": str(self.root / "results.jsonl"),
            "ADMIN_TOKEN_CACHE_PATH": str(self.root / "token-cache"),
            "MUSO_ADMIN_IDENTITY_DIR": str(self.root / "identities"),
            "CODEX_HEALTH_LIB": str(self.root / "codex-health.sh"),
            "CREDIT_APPROVAL_REGISTRY": str(registry),
        }


#: A verdict with no hold, as the admin list carries it on every item.
NO_HOLD = {"is_approved": False, "hold_reason_codes": []}


def _api_request(request_id: str, *, status: str, user: str = "u1", track: str = "t1",
                 roles: tuple[str, ...] = ("Mixing Engineer",), vd: object = NO_HOLD) -> dict:
    return {"id": request_id, "status": status, "userId": user, "trackId": track,
            "credits": list(roles), "profileId": rid(7), "verificationData": vd}


class RealEntrypointTests(unittest.TestCase):
    """The drain's approve goes through the REAL wrapper, which runs the REAL verifier.

    QA review 4 of hydra#1883: the wrapper ran ``python3 verify_anchor.py``, and the
    verifier then did ``from . import batch_admin`` with no package context. Every direct
    invocation died ``ImportError: attempted relative import with no known parent
    package``, so both gates refused every write - while the suite stayed green, because
    every other wrapper test here swaps the verifier for a stub and every verifier test
    imports the module instead of executing it. A suite that never runs the production
    entrypoint cannot see the production entrypoint is broken.

    So nothing here is a stub except the network. ``admin_writer`` builds the argv and
    environment production builds, ``bash <wrapper>`` is the whole wrapper file at its real
    relative path, the gate finds ``scripts/credit_review/verify_anchor.py`` by walking up
    from itself, and the verifier reads the claimant's profile back through the wrapper.

    ONE thing changed when approvals were bound to the drain's token (QA review 5): a
    successful write now needs ``/etc/hydra/scale-drain.token``, a root-only path no test
    may create. So the successful paths run in a MIRROR of the deployed tree - the two
    skill directories, the verifier, its batch client and the registry, byte for byte at
    their real relative paths - in which exactly one line of each wrapper differs: the
    token literal names a scratch file. ``test_the_mirror_is_the_real_tree_but_for_the_
    token_path`` holds that claim to the diff. The checked-in files themselves, unmodified,
    are exercised by the ``callers_own_token`` test, which is the half that can run
    anywhere: against the real pinned path they must refuse.
    """

    WRAPPERS = WrapperAcceptsTheRealDigestTests.WRAPPERS
    TOKEN_PIN = WrapperAcceptsTheRealDigestTests.TOKEN_PIN
    #: What the mirror carries, relative to the repo root.
    MIRRORED = ("skills-all/muso-ops-admin", "workspaces/operations/skills",
                "scripts/credit_review/verify_anchor.py",
                "scripts/credit_review/batch_admin.py",
                "policies/credit-approval-automation.json")

    @classmethod
    def setUpClass(cls):
        cls._mirror_tmp = tempfile.TemporaryDirectory()
        cls.mirror = Path(cls._mirror_tmp.name) / "tree"
        cls.token = Path(cls._mirror_tmp.name) / "scale-drain.token"
        cls.token.write_text("s3cret\n")
        cls.token.chmod(0o600)
        repo = SCRIPTS.parent
        for rel in cls.MIRRORED:
            dst = cls.mirror / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            if (repo / rel).is_dir():
                shutil.copytree(repo / rel, dst, symlinks=True,
                                ignore=shutil.ignore_patterns(".admin-token-cache"))
            else:
                shutil.copy2(repo / rel, dst)
        for wrapper in cls.WRAPPERS:
            text = (cls.mirror / wrapper).read_text()
            assert text.count(cls.TOKEN_PIN) == 1, f"{wrapper}: token pin reworded"
            (cls.mirror / wrapper).write_text(text.replace(
                cls.TOKEN_PIN, f'local drain_token_file="{cls.token}"'))

    @classmethod
    def tearDownClass(cls):
        cls._mirror_tmp.cleanup()

    def setUp(self):
        self.api = _FakeApi(Path(tempfile.mkdtemp()))
        self.registry = self.mirror / "policies/credit-approval-automation.json"
        self.decision = sd.Decision(
            rid(1), "precedent", "approve", "precedent_match",
            sd.decision_key(rid(1), "precedent", "approve"), evidence_anchor=rid(9),
            profile_id=rid(7))

    def _env(self, extra_env: dict[str, str] | None = None) -> dict[str, str]:
        return {**self.api.env(self.registry), **(extra_env or {})}

    def _writer(self, wrapper: str):
        return sd.admin_writer(str(self.mirror / wrapper), token_file=str(self.token))

    def _write(self, wrapper: str, extra_env: dict[str, str] | None = None) -> None:
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env(extra_env))
        try:
            self._writer(wrapper)(self.decision)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_the_mirror_is_the_real_tree_but_for_the_token_path(self):
        """The mirror earns the word 'real' only if this holds: every mirrored file is
        byte-identical to the checked-in one, except ONE line in each wrapper."""
        repo = SCRIPTS.parent
        differing = {}
        for rel in self.MIRRORED:
            base = repo / rel
            files = [base] if base.is_file() else [
                f for f in sorted(base.rglob("*"))
                if f.is_file() and not f.is_symlink() and f.name != ".admin-token-cache"]
            for f in files:
                twin = self.mirror / f.relative_to(repo)
                if f.read_bytes() != twin.read_bytes():
                    a, b = f.read_text().splitlines(), twin.read_text().splitlines()
                    self.assertEqual(len(a), len(b), f)
                    differing[str(f.relative_to(repo))] = [
                        (x, y) for x, y in zip(a, b) if x != y]
        self.assertEqual(sorted(differing), sorted(self.WRAPPERS))
        for rel, lines in differing.items():
            self.assertEqual(len(lines), 1, rel)
            self.assertEqual(lines[0][0].strip(), self.TOKEN_PIN)
            self.assertEqual(lines[0][1].strip(), f'local drain_token_file="{self.token}"')

    def test_an_approve_presents_the_token_to_the_real_wrapper(self):
        """The successful approve below is only meaningful if the wrapper would have
        refused it without the identity. Same call, same approved anchor, and the one
        difference is the token: wrong, or not presented at all."""
        for wrapper in self.WRAPPERS:
            for label, token_text in (("wrong", "not-the-token\n"), ("empty", "")):
                with self.subTest(wrapper=wrapper, token=label):
                    self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                    _api_request(rid(9), status="approved")], [rid(1)])
                    other = self.api.root / f"{label}.token"
                    other.write_text(token_text)
                    other.chmod(0o600)
                    saved = dict(os.environ)
                    os.environ.clear()
                    os.environ.update(self._env())
                    try:
                        with self.assertRaises(sd.DrainWriteError) as ctx:
                            sd.admin_writer(str(self.mirror / wrapper),
                                            token_file=str(other))(self.decision)
                    finally:
                        os.environ.clear()
                        os.environ.update(saved)
                    self.assertIn("SCALE_DRAIN_TOKEN does not match", str(ctx.exception))
                    self.assertEqual(self.api.requests("GET"), [])
                    self.assertEqual(self.api.requests("PUT"), [])

    def test_a_caller_supplied_registry_is_denied_by_the_real_wrapper(self):
        """QA review 5. The deployed registry authorises the drain here, so a wrapper
        that merely IGNORED the caller's registry would let this approve through. The
        attempt to name another registry is what refuses it."""
        mine = self.api.root / "my-registry.json"
        mine.write_text(self.registry.read_text())
        for wrapper in self.WRAPPERS:
            for name, value in (("CREDIT_APPROVAL_REGISTRY", str(mine)),):
                with self.subTest(wrapper=wrapper, var=name):
                    self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                    _api_request(rid(9), status="approved")], [rid(1)])
                    with self.assertRaises(sd.DrainWriteError) as ctx:
                        self._write(wrapper, {name: value})
                    self.assertIn("cannot be redirected", str(ctx.exception))
                    self.assertEqual(self.api.requests("GET"), [])
                    self.assertEqual(self.api.requests("PUT"), [])

    def test_an_approve_with_a_real_approved_anchor_reaches_the_api(self):
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="approved")], [rid(1)])
                self._write(wrapper)
                # the verifier asked the API about the claimant's profile...
                reads = self.api.requests("GET")
                self.assertEqual(len(reads), 1, reads)
                self.assertIn(f"profilesIds={rid(7)}", reads[0])
                # ...and only then did the approve land
                writes = self.api.requests("PUT")
                self.assertEqual(len(writes), 1, writes)
                self.assertIn("/admin/credit-requests", writes[0])
                self.assertIn(rid(1), writes[0])
                # The wrapper the drain runs in production (the operations copy) names
                # the drain's automation to core, on the drain's own login. The
                # skills-all copy has no automation identities and sends no such header.
                header = "X-Credit-Automation-Id: verification-scale-drain"
                if wrapper == Path(sd.ADMIN_WRITER_SCRIPT).relative_to("/opt/hydra").as_posix():
                    self.assertIn(header, writes[0])
                    self.assertEqual(writes[0].count("X-Credit-Automation-Id:"), 1)
                else:
                    self.assertNotIn("X-Credit-Automation-Id:", writes[0])

    def test_an_approve_of_a_request_on_hold_never_reaches_the_api(self):
        """The real wrapper, end to end: a good anchor, and the request went on hold after
        the plan was made. The hold of 2026-11-13 (``track_pending_capture``, risk 100) is
        the fixture; the PUT must not happen."""
        vd = {"is_approved": False, "hold_reason_codes": ["track_pending_capture"],
              "rule_risk_percent": {"track_pending_capture": 100}, "total_risk_percent": 100}
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed", vd=vd),
                                _api_request(rid(9), status="approved")], [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper)
                self.assertIn("on hold (track_pending_capture)", str(ctx.exception))
                self.assertEqual(self.api.requests("PUT"), [])

    def test_an_approve_of_a_request_on_a_hold_the_guard_covers_reaches_the_api(self):
        """The same hold code beside a rule core's guard holds on: this gate stands aside
        and the approve goes to core, whose refusal is the one ``apply`` routes."""
        vd = {"is_approved": False,
              "hold_reason_codes": ["track_pending_capture", "review_role_cardinality"],
              "rule_risk_percent": {"track_pending_capture": 100, "review_role_cardinality": 30}}
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed", vd=vd),
                                _api_request(rid(9), status="approved")], [rid(1)])
                self._write(wrapper)
                self.assertEqual(len(self.api.requests("PUT")), 1)

    def test_an_approve_whose_anchor_is_not_approved_never_reaches_the_api(self):
        """The twin that keeps the test above honest: the same call, an anchor the API
        reports as still pending, and the write must not happen. Without this, a verifier
        that passed everything would look identical to one that works."""
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="unverified")], [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper)
                self.assertIn("not approved", str(ctx.exception))
                self.assertEqual(self.api.requests("PUT"), [])

    def _fabricator(self) -> tuple[Path, Path]:
        """An 'admin script' that answers call-batch with exactly what the verifier needs
        to pass: the target pending and the anchor APPROVED for the same claim. It also
        leaves a marker, so a test can tell 'refused' from 'ran and happened to fail'."""
        marker = self.api.root / "fabricator-ran"
        script = self.api.root / "fake-admin.sh"
        body = {"data": {"items": [_api_request(rid(1), status="user_verification_needed"),
                                   _api_request(rid(9), status="approved")]}}
        row = json.dumps({"id": "one", "http_status": 200, "body": body})
        script.write_text("#!/usr/bin/env bash\n"
                          f": > {marker}\n"
                          "cat >/dev/null\n"
                          f"printf '%s\\n' '{row}'\n")
        script.chmod(0o755)
        return script, marker

    def test_the_fabricated_response_would_verify_if_it_were_read(self):
        """Pins that the fabricator below is a working attack and not a strawman: handed
        to the batch client directly, its response satisfies the precedent check."""
        from credit_review import batch_admin, verify_anchor
        script, marker = self._fabricator()
        verify_anchor.verify_precedent(batch_admin.BatchAdmin(script=str(script)),
                                       rid(1), rid(9), rid(7))
        self.assertTrue(marker.exists())

    def test_a_caller_supplied_admin_script_is_denied(self):
        """QA review 4, finding 1. The API says the anchor is NOT approved; the caller
        points CREDIT_REVIEW_ADMIN_SCRIPT at a script that says it is. The verifier must
        refuse the redirect - never run the script, never approve - and say why."""
        script, marker = self._fabricator()
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="unverified")], [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper, {"CREDIT_REVIEW_ADMIN_SCRIPT": str(script)})
                self.assertIn("CREDIT_REVIEW_ADMIN_SCRIPT", str(ctx.exception))
                self.assertFalse(marker.exists(), "the caller's admin script was executed")
                self.assertEqual(self.api.requests("PUT"), [])

    def test_the_override_is_denied_even_when_the_api_would_have_agreed(self):
        """Denied, not ignored. Here the real API WOULD verify the approve (see the first
        test in this class), so a verifier that ignored the override and read through the
        pinned wrapper would let it through. The redirect attempt alone refuses it."""
        script, marker = self._fabricator()
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="approved")], [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper, {"CREDIT_REVIEW_ADMIN_SCRIPT": str(script)})
                self.assertIn("CREDIT_REVIEW_ADMIN_SCRIPT", str(ctx.exception))
                self.assertFalse(marker.exists())
                self.assertEqual(self.api.requests("GET"), [])
                self.assertEqual(self.api.requests("PUT"), [])

    def test_the_pinned_path_named_explicitly_is_not_a_redirect(self):
        """A host that exports the canonical wrapper path for the other credit tools is
        not attacking anything; only a DIFFERENT script is refused."""
        pinned = self.mirror / "workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
        self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                        _api_request(rid(9), status="approved")], [rid(1)])
        self._write(self.WRAPPERS[0], {"CREDIT_REVIEW_ADMIN_SCRIPT": str(pinned)})
        self.assertEqual(len(self.api.requests("PUT")), 1)

    def test_a_caller_python_path_cannot_substitute_the_batch_client(self):
        """The verifier runs isolated (python3 -I) and loads its batch client from its own
        directory, so a PYTHONPATH carrying a look-alike changes nothing."""
        hostile = self.api.root / "hostile"
        marker = self.api.root / "hostile-imported"
        (hostile / "credit_review").mkdir(parents=True)
        payload = f"open({str(marker)!r}, 'w').close()\nraise SystemExit(0)\n"
        for name in ("batch_admin.py", "credit_review/__init__.py",
                     "credit_review/batch_admin.py", "verify_anchor.py"):
            (hostile / name).write_text(payload)
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="unverified")], [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper, {"PYTHONPATH": str(hostile)})
                self.assertIn("not approved", str(ctx.exception))
                self.assertFalse(marker.exists(), "a module from PYTHONPATH was imported")
                self.assertEqual(len(self.api.requests("GET")), 1)
                self.assertEqual(self.api.requests("PUT"), [])

    PROOF_STORE_PIN = 'PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"'

    def _proof_tree(self, verdicts) -> Path:
        """A second mirror whose verifier reads a scratch proof store.

        The proof store is a constant in the verifier and the wrapper never passes
        ``--proof-store``, so the only way to run a proof approve end to end off node-8
        is the one used for the token path: copy the tree and rewrite that ONE literal.
        The copy's verifier is asserted to differ from the checked-in file by that line
        and no other.
        """
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        tree = root / "tree"
        shutil.copytree(self.mirror, tree, symlinks=True)
        store = root / "proof.sqlite"
        db = sqlite3.connect(store)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO verdicts (proof_id, request_id, verdict, created_at)"
                       " VALUES (?,?,?,?)", verdicts)
        db.commit()
        db.close()
        verifier = tree / "scripts/credit_review/verify_anchor.py"
        real = (SCRIPTS / "credit_review/verify_anchor.py").read_text()
        self.assertEqual(real.count(self.PROOF_STORE_PIN), 1, "proof store pin reworded")
        verifier.write_text(real.replace(self.PROOF_STORE_PIN, f'PROOF_STORE = "{store}"'))
        differing = [(x, y) for x, y in zip(real.splitlines(),
                                            verifier.read_text().splitlines()) if x != y]
        self.assertEqual(len(differing), 1, differing)
        return tree

    def _proof_write(self, tree: Path, wrapper: str, proof: str) -> None:
        decision = sd.Decision(
            rid(1), "proof_verdict", "approve", "proof_verdict_approve",
            sd.decision_key(rid(1), "proof_verdict", "approve"), evidence_anchor=proof,
            profile_id=rid(7))
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self.api.env(tree / "policies/credit-approval-automation.json"))
        try:
            sd.admin_writer(str(tree / wrapper), token_file=str(self.token))(decision)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_a_proof_approve_is_checked_against_the_roles_the_live_request_claims(self):
        """QA review 6 of hydra#1883, through both real entrypoints. The proof gate read
        only the store, so it approved on whatever claims happened to be on file: a
        Composer + Producer request with one GENUINE Composer verdict and nothing for
        Producer passed, on a stale or edited plan. The gate now reads the request as it
        stands and needs a verdict for every role it claims."""
        proof = "a" * 64
        composer = (proof, f"{rid(1)}#Composer", "GENUINE", "2026-11-02T00:00:00Z")
        producer = (proof, f"{rid(1)}#Producer", "VERIFIED", "2026-11-02T00:00:00Z")
        live = [_api_request(rid(1), status="user_verification_needed",
                             roles=("Composer", "Producer"))]
        covered = self._proof_tree([composer, producer])
        omitted = self._proof_tree([composer])
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper, case="every claimed role has its verdict"):
                self.api.serve(live, [rid(1)])
                self._proof_write(covered, wrapper, proof)
                reads = self.api.requests("GET")
                self.assertEqual(len(reads), 1, reads)
                self.assertIn(f"profilesIds={rid(7)}", reads[0])
                self.assertEqual(len(self.api.requests("PUT")), 1)
            with self.subTest(wrapper=wrapper, case="a claimed role has no verdict"):
                self.api.serve(live, [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._proof_write(omitted, wrapper, proof)
                self.assertIn("claims producer with no verdict on file", str(ctx.exception))
                self.assertEqual(len(self.api.requests("GET")), 1)
                self.assertEqual(self.api.requests("PUT"), [])
            with self.subTest(wrapper=wrapper, case="the request gained a role since the plan"):
                # the same store that passed above; only the live request changed
                self.api.serve([_api_request(rid(1), status="user_verification_needed",
                                             roles=("Composer", "Producer", "Lyricist"))],
                               [rid(1)])
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._proof_write(covered, wrapper, proof)
                self.assertIn("claims lyricist with no verdict on file", str(ctx.exception))
                self.assertEqual(self.api.requests("PUT"), [])

    def _reject(self, wrapper: str, ids: list[str], path: str) -> subprocess.CompletedProcess:
        """A ``rejected`` body sent as the drain would have sent a duplicate close: its
        requester, its flag, its token, an approved registry entry and the old digest.
        ``wrapper`` is a path to run, so the mirror and the checked-in file both serve."""
        evidence = f"drain-dup:{rid(9)};duplicate_of_decided;v{sd.RULE_VERSION};{rid(7)}"
        body = json.dumps({"expectedStatus": "unverified", "requestIds": ids,
                           "status": "rejected"}, sort_keys=True)
        env = {**self._env(), "SCALE_DRAIN": "1", "SCALE_DRAIN_TOKEN": "s3cret",
               "EVIDENCE_EXCERPT": evidence, "OPS_DRY_RUN": "0"}
        return subprocess.run(
            ["bash", wrapper, "--evidence-excerpt", evidence, "--requester",
             sd.SERVICE_REQUESTER, "call", "PUT", path, body],
            capture_output=True, text=True, env=env, check=False)

    def test_a_rejected_body_from_the_drains_identity_never_reaches_the_api(self):
        """The wrapper has no drain exception to the reject gate. This is the call that
        used to close a duplicate - a pending target, an approved original of the same
        claim, the token, the registry, the digest - and it stops at the reject gate
        before any request: core would have told the customer "rejected"."""
        for wrapper in self.WRAPPERS:
            for path in ("/admin/credit-requests/conditional-status", "/admin/credit-requests"):
                for ids in ([rid(1)], [rid(1), rid(2)]):
                    with self.subTest(wrapper=wrapper, path=path, ids=len(ids)):
                        self.api.serve([_api_request(rid(1), status="unverified"),
                                        _api_request(rid(9), status="approved")], ids)
                        proc = self._reject(str(self.mirror / wrapper), ids, path)
                        self.assertNotEqual(proc.returncode, 0, proc.stdout)
                        self.assertIn("MUSO_CREDIT_REJECT_APPROVAL_REQUIRED", proc.stderr)
                        self.assertEqual(self.api.requests("PUT"), [])
                        self.assertEqual(self.api.requests("GET"), [])

    def test_no_wrapper_carries_a_duplicate_close_predicate(self):
        """The registry check enumerates ``is_*_approval`` only, so a close predicate
        that came back would be registered nowhere. Neither copy defines one."""
        for wrapper in self.WRAPPERS:
            proc = subprocess.run(
                ["bash", "-c", 'main() { :; }; source "$1" >/dev/null 2>&1; '
                               "declare -F | awk '{print $3}'", "_", str(SCRIPTS.parent / wrapper)],
                capture_output=True, text=True, check=False)
            names = proc.stdout.split()
            self.assertIn("is_scale_drain_approval", names, proc.stderr)
            self.assertEqual([n for n in names if "duplicate" in n], [], wrapper)

    @unittest.skipIf(os.path.exists("/etc/hydra/scale-drain.token"),
                     "this host carries the real drain token")
    def test_an_approve_with_a_callers_own_token_never_reaches_the_api(self):
        """The approve path, CHECKED-IN wrapper, real pinned path, and an approve the API
        would fully verify. The caller's own mode-600 token is not the drain's identity:
        the wrapper reads only /etc/hydra/scale-drain.token and refuses before the
        verifier or the API is asked anything."""
        own = self.api.root / "mine.token"
        own.write_text("attacker\n")
        own.chmod(0o600)
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="approved")], [rid(1)])
                saved = dict(os.environ)
                os.environ.clear()
                os.environ.update(self.api.env())
                try:
                    with self.assertRaises(sd.DrainWriteError) as ctx:
                        sd.admin_writer(str(SCRIPTS.parent / wrapper),
                                        token_file=str(own))(self.decision)
                finally:
                    os.environ.clear()
                    os.environ.update(saved)
                self.assertIn("scale-drain.token is missing", str(ctx.exception))
                self.assertEqual(self.api.requests("GET"), [])
                self.assertEqual(self.api.requests("PUT"), [])

    # ── a write that landed and was never confirmed (QA review 5) ────────────
    #: One real apply in a child: the real writer, through the real wrapper, and then a
    #: SIGKILL the instant the wrapper returns - after the PUT, before the confirm.
    CRASH_AFTER_REAL_WRITE = r"""
import os, signal, sys
sys.path.insert(0, sys.argv[1])
from credit_review import scale_drain as sd
plan, ledger, wrapper, token = sys.argv[2:6]
real = sd.admin_writer(wrapper, token_file=token)
def writer(d):
    real(d)
    os.kill(os.getpid(), signal.SIGKILL)
sd.apply(sd.parse_plan(open(plan, "rb").read()), sd.open_ledger(ledger),
         shards=1, write_pool=1, writer=writer)
"""

    def _in_api_env(self, fn):
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env())
        try:
            return fn()
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def _resume(self, wrapper, ledger):
        """What ``scale_drain apply`` does on a restart: the real writer and the real
        reconciler, which reads through the verifier's pinned wrapper."""
        db = sd.open_ledger(ledger)
        stats = self._in_api_env(lambda: sd.apply(
            [self.decision], db, shards=1, write_pool=1,
            writer=self._writer(wrapper), reconciler=sd.live_reconciler()))
        intents = db.execute("SELECT state, resolution FROM intents").fetchall()
        applied = db.execute("SELECT request_id FROM applied").fetchall()
        return stats, intents, applied

    def _now(self, delta_s=0):
        return (datetime.now(timezone.utc) + timedelta(seconds=delta_s)).strftime(
            "%Y-%m-%dT%H:%M:%S.%fZ")

    def _live(self, target_status, *, updated_at=None, anchor_status="approved"):
        """Change what the API reports WITHOUT clearing the request log."""
        target = _api_request(rid(1), status=target_status)
        if updated_at:
            target["updatedAt"] = updated_at
        self.api.items.write_text(json.dumps({"data": {"items": [
            target, _api_request(rid(9), status=anchor_status)]}}))

    def test_a_real_write_killed_before_its_confirm_is_reconciled_not_repeated(self):
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                ledger = str(self.api.root / f"ledger-{self.WRAPPERS.index(wrapper)}.sqlite")
                plan = self.api.root / "plan.jsonl"
                plan.write_bytes(sd.serialize([self.decision]))
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="approved")], [rid(1)])
                proc = subprocess.run(
                    [sys.executable, "-c", self.CRASH_AFTER_REAL_WRITE, str(SCRIPTS),
                     str(plan), ledger, str(self.mirror / wrapper), str(self.token)],
                    capture_output=True, text=True, env=self._env(), check=False)
                self.assertEqual(proc.returncode, -signal.SIGKILL, proc.stderr)
                # the approve reached the API, and the ledger has only the intent
                self.assertEqual(len(self.api.requests("PUT")), 1)
                db = sd.open_ledger(ledger)
                self.assertEqual(db.execute("SELECT state FROM intents").fetchall(),
                                 [("planned",)])
                self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)
                db.close()
                # the backend now reports what that PUT did
                self._live("approved", updated_at=self._now())

                # THE BUG, kept visible: writing it again is refused by the gate, every
                # time, because the request is no longer pending. Retrying could never
                # have recorded this row.
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    self._write(wrapper)
                self.assertIn("already approved", str(ctx.exception))
                self.assertEqual(len(self.api.requests("PUT")), 1)

                stats, intents, applied = self._resume(wrapper, ledger)
                self.assertEqual((stats["reconciled"], stats["applied"], stats["errors"]),
                                 (1, 1, 0), stats)
                self.assertEqual(intents, [("confirmed", "reconciled")])
                self.assertEqual(applied, [(rid(1),)])
                # zero duplicates: still the one PUT the dead process made
                self.assertEqual(len(self.api.requests("PUT")), 1)
                self.assertTrue(sd.verify([self.decision], sd.open_ledger(ledger))["ok"])

    def _open_intent(self, name):
        ledger = str(self.api.root / name)
        sd._record_intent(sd.open_ledger(ledger), self.decision, 0,
                          datetime.now(timezone.utc))
        return ledger

    def test_an_approval_that_predates_our_intent_is_not_claimed(self):
        """Approved by somebody else, before this drain ever planned to: the ledger must
        not say we did it, and the request must not be touched."""
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        self._live("approved", updated_at=self._now(-3600))
        stats, intents, applied = self._resume(wrapper, self._open_intent("before.sqlite"))
        self.assertEqual(intents, [("abandoned", "decided_before_intent")])
        self.assertEqual(applied, [])
        self.assertEqual((stats["abandoned"], stats["reconciled"]), (1, 0))
        self.assertEqual(self.api.requests("PUT"), [])

    def test_an_approval_this_decision_could_not_have_made_is_not_claimed(self):
        """Approved after our intent, but the precedent we cited is not approved - so the
        gate refused us, and the approval is somebody else's."""
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("unanchored.sqlite")
        self._live("approved", updated_at=self._now(), anchor_status="unverified")
        stats, intents, applied = self._resume(wrapper, ledger)
        self.assertEqual(intents, [("abandoned", "anchor_unverified")])
        self.assertEqual(applied, [])
        self.assertEqual(self.api.requests("PUT"), [])

    def test_a_request_somebody_rejected_is_abandoned_not_overwritten(self):
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("rejected.sqlite")
        self._live("rejected", updated_at=self._now())
        stats, intents, applied = self._resume(wrapper, ledger)
        self.assertEqual(intents, [("abandoned", "target_rejected")])
        self.assertEqual(applied, [])
        self.assertEqual(self.api.requests("PUT"), [])

    def test_a_still_pending_request_is_written_through_the_gate(self):
        """The intent was recorded and the write never happened: the restart makes it,
        once, by the same gated path as any other approve."""
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("pending.sqlite")
        self._live("user_verification_needed")
        stats, intents, applied = self._resume(wrapper, ledger)
        self.assertEqual(intents, [("confirmed", "written")])
        self.assertEqual(applied, [(rid(1),)])
        self.assertEqual(len(self.api.requests("PUT")), 1)
        self.assertEqual(stats["reconciled"], 0)

    def test_an_api_that_cannot_answer_settles_nothing(self):
        """Not a verdict in either direction: no write, no confirm, no abandon."""
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("outage.sqlite")
        self.api.items.write_text('{"error": "upstream"}')
        stats, intents, applied = self._resume(wrapper, ledger)
        self.assertEqual(intents, [("planned", None)])
        self.assertEqual(applied, [])
        self.assertEqual((stats["unreconciled"], stats["errors"]), (1, 1))
        self.assertEqual(self.api.requests("PUT"), [])

    def test_the_reconcile_read_cannot_be_redirected_either(self):
        """A caller's admin script would happily report the request approved. The
        reconciler reads through the verifier's pinned wrapper or not at all."""
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("redirected.sqlite")
        self._live("user_verification_needed")
        script, marker = self._fabricator()
        db = sd.open_ledger(ledger)
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env({"CREDIT_REVIEW_ADMIN_SCRIPT": str(script)}))
        try:
            stats = sd.apply([self.decision], db, shards=1, write_pool=1,
                             writer=self._writer(wrapper),
                             reconciler=sd.live_reconciler())
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(db.execute("SELECT state FROM intents").fetchall(), [("planned",)])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)
        self.assertEqual(stats["unreconciled"], 1)
        self.assertFalse(marker.exists())
        self.assertEqual(self.api.requests("PUT"), [])

    # -- a failed write names its cause (2026-11-13) --------------------------------
    #
    # Same seam as everything above: the real wrapper, the real gate, the real verifier,
    # and only the network replaced. What is pinned here is the text the REAL files
    # print, because the classification reads that text and a reworded refusal would
    # otherwise fall back to ``wrapper_failed`` with every test still green.

    def _serve_approvable(self):
        self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                        _api_request(rid(9), status="approved")], [rid(1)])

    def _refusal(self, wrapper, extra_env=None, *, drop=()):
        """The error the drain's writer raises for one approve, in a given environment."""
        env = self._env(extra_env)
        for name in drop:
            env.pop(name)
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        try:
            with self.assertRaises(sd.DrainWriteError) as ctx:
                self._writer(wrapper)(self.decision)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        return ctx.exception

    def test_a_shell_without_the_admin_env_is_a_run_failure_named_as_one(self):
        """2026-11-11, reproduced: the wrapper dies in ``check_env`` before its gate, for
        every row alike. It reaches neither the verifier's read nor the PUT."""
        for wrapper in self.WRAPPERS:
            for name in sd.ADMIN_ENV_REQUIRED:
                with self.subTest(wrapper=wrapper, missing=name):
                    self._serve_approvable()
                    exc = self._refusal(wrapper, drop=(name,))
                    self.assertIsInstance(exc, sd.DrainConfigError)
                    self.assertEqual(exc.failure_class, "admin_env_missing")
                    self.assertIn(f"{name} not set", str(exc))
                    self.assertEqual(self.api.requests("GET"), [])
                    self.assertEqual(self.api.requests("PUT"), [])

    def test_a_token_the_wrapper_refuses_is_a_run_failure_not_a_gate_riddle(self):
        """The refused drain predicate falls through to the generic gate, which appends a
        line about a missing session log. The cause is the token, and it is the run's."""
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self._serve_approvable()
                other = self.api.root / "other.token"
                other.write_text("not-the-token\n")
                other.chmod(0o600)
                saved = dict(os.environ)
                os.environ.clear()
                os.environ.update(self._env())
                try:
                    with self.assertRaises(sd.DrainConfigError) as ctx:
                        sd.admin_writer(str(self.mirror / wrapper),
                                        token_file=str(other))(self.decision)
                finally:
                    os.environ.clear()
                    os.environ.update(saved)
                self.assertEqual(ctx.exception.failure_class, "drain_token")
                self.assertEqual(self.api.requests("PUT"), [])

    def test_a_token_file_that_is_not_there_is_a_run_failure_before_the_wrapper_runs(self):
        self._serve_approvable()
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env())
        try:
            with self.assertRaises(sd.DrainConfigError) as ctx:
                sd.admin_writer(str(self.mirror / self.WRAPPERS[0]),
                                token_file=str(self.api.root / "absent.token"))(self.decision)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(ctx.exception.failure_class, "drain_token")
        self.assertEqual(self.api.log.read_text(), "")

    def test_an_unapproved_anchor_is_a_row_failure_and_the_run_goes_on(self):
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                self.api.serve([_api_request(rid(1), status="user_verification_needed"),
                                _api_request(rid(9), status="rejected")], [rid(1)])
                exc = self._refusal(wrapper)
                self.assertNotIsInstance(exc, sd.DrainConfigError)
                self.assertEqual(exc.failure_class, "anchor_unverified")
                self.assertEqual(self.api.requests("PUT"), [])

    # -- cause 2: core refuses an agent approve its validator did not approve --------

    CORE_REFUSAL = {
        "result": "error", "code": 400, "errorCode": "agent_cannot_approve_declined",
        "message": "an autonomous agent cannot approve 1 credit request(s) the validator "
                   "did not approve (only a registered automation bound to this token "
                   "account, on a row inside its scope, may) \u2014 nothing was written; "
                   "route them to a credit case or a named human",
        "refusedRequestIds": [rid(1)],
        "refused": [{"id": rid(1), "band": "A_auto",
                     "reasons": ["validator_not_approved", "no_registered_automation"]}],
    }
    #: The same code for a row core JUDGED: the account is registered, the row is outside
    #: its scope. core names the row's facts and never ``no_registered_automation``.
    CORE_ROW_REFUSAL = {
        **CORE_REFUSAL,
        "refused": [{"id": rid(1), "band": "B_request_info",
                     "reasons": ["no_sound_precedent", "tier_t1_needs_evidence"]}],
    }

    def _core_answers(self, body, status):
        self._serve_approvable()
        self.api.put_body.write_text(json.dumps(body))
        return {"FAKE_API_PUT_STATUS": str(status)}

    def test_cores_agent_guard_refusal_is_its_own_error_not_a_generic_400(self):
        """The approve passed hydra's gate - token, registry, verified anchor - and
        reached core, which refused it: the account is not a registered automation bound
        to that account THERE. Before this the row read ``wrapper reported HTTP 400``,
        the same words as a malformed body or an unknown id."""
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                exc = self._refusal(wrapper, self._core_answers(self.CORE_REFUSAL, 400))
                self.assertIsInstance(exc, sd.DrainRefusedByCore)
                self.assertEqual(exc.failure_class, "core_automation_not_registered")
                # it is a fact about core's register, not about this run's environment:
                # the next row may be one the validator approved
                self.assertNotIsInstance(exc, sd.DrainConfigError)
                said = str(exc)
                self.assertIn(rid(1), said)
                self.assertIn("agent_cannot_approve_declined", said)
                self.assertIn("band=A_auto reasons=validator_not_approved,no_registered_automation",
                              said)
                # who to register, and where: the identity the approve signed in as, and
                # the hydra half that is already in place
                self.assertIn("MUSO_ADMIN_IDENTITY=scale-drain", said)
                self.assertIn("verification-scale-drain", said)
                self.assertIn("core-backend", said)
                self.assertIn("nothing written", said)
                # the gate let it through: this is the one refusal that costs a PUT
                self.assertEqual(len(self.api.requests("PUT")), 1)

    def test_a_row_core_judged_and_refused_is_not_called_a_registration_gap(self):
        """Once the account IS registered, core still answers this code for a row outside
        the scope (no sound precedent, a big track, claimant proof owed). Calling that
        "register the automation" sends a person to do something already done."""
        for wrapper in self.WRAPPERS:
            with self.subTest(wrapper=wrapper):
                exc = self._refusal(wrapper, self._core_answers(self.CORE_ROW_REFUSAL, 400))
                self.assertIsInstance(exc, sd.DrainRowRefusedByCore)
                self.assertEqual(exc.failure_class, "core_row_refused")
                self.assertNotIsInstance(exc, sd.DrainConfigError)
                said = str(exc)
                self.assertIn("reasons=no_sound_precedent,tier_t1_needs_evidence", said)
                self.assertIn("nothing written", said)
                self.assertNotIn("needs a registration", said)
                self.assertEqual(exc.reasons, ("no_sound_precedent", "tier_t1_needs_evidence"))

    def test_the_refusal_names_the_identity_when_the_wrapper_logs_in_by_identity(self):
        exc = sd._refused_by_core(self.decision, 400, self.CORE_REFUSAL,
                                  sd._account({"MUSO_ADMIN_IDENTITY": "credit-decider",
                                               "MUSO_ADMIN_EMAIL": "ignored@example.com"}))
        self.assertIn("MUSO_ADMIN_IDENTITY=credit-decider", str(exc))
        self.assertNotIn("ignored@example.com", str(exc))

    def test_the_guard_is_recognised_by_its_message_when_core_sends_no_code(self):
        """The 93 rows in the credit-review ledger carry the message and no errorCode."""
        body = {"result": "error", "code": 400, "message": self.CORE_REFUSAL["message"]}
        exc = self._refusal(self.WRAPPERS[0], self._core_answers(body, 400))
        self.assertIsInstance(exc, sd.DrainRefusedByCore)

    def test_any_other_4xx_or_5xx_stays_a_plain_http_error(self):
        """The classification must not swallow every 400: a different refusal is a
        different cause, and calling it a registration gap would send someone to
        register an automation that is already registered."""
        others = [
            (400, {"result": "error", "code": 400, "errorCode": "invalid_status_transition",
                   "message": "cannot move an approved request to approved"}),
            (403, {"result": "error", "code": 403, "message": "Forbidden"}),
            (503, {"result": "error", "code": 503, "message": "Unavailable service"}),
        ]
        for status, body in others:
            with self.subTest(status=status):
                exc = self._refusal(self.WRAPPERS[0], self._core_answers(body, status))
                self.assertNotIsInstance(exc, sd.DrainRefusedByCore)
                self.assertNotIsInstance(exc, sd.DrainConfigError)
                self.assertEqual(exc.failure_class, "http_error")
                self.assertIn(f"HTTP {status}", str(exc))
                self.assertIn(body["message"], str(exc))

    def test_a_200_that_names_no_row_is_still_not_an_approval(self):
        """Not a 200: the acceptance is the row the backend names."""
        self._serve_approvable()
        self.api.put_body.write_text(json.dumps({"data": {"updatedIds": []}}))
        exc = self._refusal(self.WRAPPERS[0])
        self.assertNotIsInstance(exc, sd.DrainRefusedByCore)
        self.assertIn(rid(1), str(exc))

    def test_a_core_refusal_leaves_the_intent_open_and_the_ledger_unapproved(self):
        """Through ``apply``: counted by cause, nothing recorded as applied, and the
        request (still pending in core) is retried by a later run, never marked done."""
        wrapper = self.WRAPPERS[0]
        extra = self._core_answers(self.CORE_REFUSAL, 400)
        db = sd.open_ledger(str(self.api.root / "refused.sqlite"))
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env(extra))
        try:
            stats = sd.apply([self.decision], db, shards=1, write_pool=1,
                             writer=self._writer(wrapper), reconciler=sd.live_reconciler())
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(stats["error_classes"], {"core_automation_not_registered": 1})
        self.assertEqual((stats["applied"], stats["errors"], stats["stopped"]), (0, 1, False))
        self.assertEqual(db.execute("SELECT state FROM intents").fetchall(), [("planned",)])
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)

    # -- the resumed pass, and the command an operator actually runs -----------------

    def test_a_resume_without_the_admin_env_says_so_and_stops(self):
        """The reconcile read goes through the same wrapper and dies of the same cause.
        The batch client's error is not one of the verifier's, so it used to reach
        ``apply`` as an anonymous exception: errors 1, unreconciled 1, stderr empty."""
        import contextlib
        import io
        wrapper = self.WRAPPERS[0]
        self.api.serve([], [rid(1)])
        ledger = self._open_intent("no-env.sqlite")
        self._live("user_verification_needed")
        db = sd.open_ledger(ledger)
        env = self._env()
        env.pop("MUSO_API_URL")
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(env)
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                stats = sd.apply([self.decision], db, shards=1, write_pool=1,
                                 writer=self._writer(wrapper),
                                 reconciler=sd.live_reconciler())
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(stats["error_classes"], {"admin_env_missing": 1}, err.getvalue())
        self.assertEqual((stats["unreconciled"], stats["stopped"]), (1, True))
        self.assertIn("MUSO_API_URL not set", stats["stopped_reason"])
        self.assertIn(f"RECONCILEFAIL {rid(1)}:", err.getvalue())
        self.assertEqual(db.execute("SELECT state FROM intents").fetchall(), [("planned",)])
        self.assertEqual(self.api.requests("PUT"), [])

    def _apply_cli(self, env, ledger, *extra):
        plan = self.api.root / "plan.jsonl"
        plan.write_bytes(sd.serialize([self.decision]))
        return subprocess.run(
            cli("apply", "--plan", str(plan), "--ledger", str(ledger),
                "--admin-script", str(self.mirror / self.WRAPPERS[0]), *extra),
            capture_output=True, text=True, cwd=str(SCRIPTS), env=env, check=False)

    def test_apply_refuses_to_start_from_a_shell_that_cannot_write(self):
        """``scale_drain apply`` from a bare shell: one line per cause, exit 2, and NOT
        ONE intent recorded. On 2026-11-11 the same command recorded 3,326."""
        ledger = self.api.root / "cli.sqlite"
        env = self._env()
        for name in sd.ADMIN_ENV_REQUIRED:
            env.pop(name)
        proc = self._apply_cli(env, ledger)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertIn("admin_env_missing", out["preflight_failed"])
        self.assertEqual((out["writes_pending"], out["applied"]), (1, 0))
        self.assertIn("PREFLIGHT admin_env_missing: MUSO_API_URL, MUSO_ADMIN_EMAIL, "
                      "MUSO_ADMIN_PASSWORD not set", proc.stderr)
        self.assertFalse(self.api.log.exists(), "the preflight reached the network")
        db = sd.open_ledger(str(ledger))
        self.assertEqual(db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)

    def test_the_cli_grants_the_approval_and_reads_it_back_from_the_ledger(self):
        """The acceptance, end to end: ``scale_drain apply`` from a shell that CAN write
        lands the approve through the real wrapper and gate, and a read of the LIVE
        request after the write - not the HTTP code - is what records it as granted.

        Same seam as the class: the network is the only stub (``_FakeApi``); the wrapper,
        its gate chain, the verifier and the batch client are the real files, and core
        answers with the row it wrote. The ONE injection is the drain's root-only token
        path, which no test may create - a mirror token stands in for it (the wrapper in
        ``self.mirror`` is pointed at the same file). A 200 that named no row is refused
        by the test next to this one."""
        from unittest import mock
        ledger = self.api.root / "granted.sqlite"
        plan = self.api.root / "plan.jsonl"
        plan.write_bytes(sd.serialize([self.decision]))
        real_writer = sd.admin_writer
        real_preflight = sd.admin_preflight
        granted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        precedent = _api_request(rid(9), status="approved")
        self.api.serve(
            [_api_request(rid(1), status="user_verification_needed"), precedent], [rid(1)],
            after_put=[{**_api_request(rid(1), status="approved"), "updatedAt": granted_at},
                       precedent])
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(self._env())
        try:
            with mock.patch.object(
                    sd, "admin_writer",
                    lambda script=None: real_writer(script, token_file=str(self.token))), \
                    mock.patch.object(
                        sd, "admin_preflight",
                        lambda script=None, **kw: real_preflight(
                            script, token_file=str(self.token), **kw)):
                import contextlib
                import io
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = sd._main(["apply", "--plan", str(plan),
                                   "--ledger", str(ledger),
                                   "--admin-script", str(self.mirror / self.WRAPPERS[0])])
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(rc, 0)
        stats = json.loads(out.getvalue().splitlines()[-1])
        self.assertEqual((stats["applied"], stats["errors"], stats["stopped"]), (1, 0, False))
        self.assertEqual(stats["error_classes"], {})
        self.assertEqual((stats["attempted"], stats["failures"]), (1, {}))
        writes = self.api.requests("PUT")
        self.assertEqual(len(writes), 1, writes)
        self.assertIn("requestIds", writes[0])
        self.assertIn(rid(1), writes[0])
        db = sd.open_ledger(str(ledger))
        self.assertEqual(
            db.execute("SELECT request_id, outcome FROM applied").fetchall(),
            [(rid(1), "approve")])
        self.assertEqual(
            db.execute("SELECT state FROM intents").fetchall(), [("confirmed",)])
        self.assertTrue(sd.verify([self.decision], db)["ok"])

    def test_the_preflight_is_not_asked_of_a_run_that_writes_nothing(self):
        """A rehearsal and a dry run need no admin env, and must not start needing one."""
        env = {k: v for k, v in self._env().items() if k not in sd.ADMIN_ENV_REQUIRED}
        for flag in ("--no-write", "--dry-run"):
            with self.subTest(flag=flag):
                proc = self._apply_cli(env, self.api.root / f"{flag.strip('-')}.sqlite", flag)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertNotIn("PREFLIGHT", proc.stderr)


# The answer production gave on 2026-11-13 00:38:08Z to the drain's one real approve
# (node-8 /var/log/openclaw/credit-batch-runs/2026-11-13/, requester scale-drain@hydra-ops),
# verbatim. The wrapper exits 0 on it and wraps it in its envelope.
CORE_REFUSAL = (
    '{"result":"error","message":"an autonomous agent cannot approve 1 credit request(s) the '
    'validator did not approve (only a registered automation bound to this token account, on '
    'a row inside its scope, may) \u2014 nothing was written; route them to a credit case or a '
    'named human","errorCode":"agent_cannot_approve_declined","refusedRequestIds":'
    '["000decc0-43f8-4aec-bd6b-e03e7d0651f4"],"refused":[{"id":'
    '"000decc0-43f8-4aec-bd6b-e03e7d0651f4","band":"A_auto","reasons":'
    '["validator_not_approved","no_registered_automation"]}],"code":400}')
REFUSED_ID = "000decc0-43f8-4aec-bd6b-e03e7d0651f4"


def refusal_envelope(request_id: str = REFUSED_ID) -> str:
    body = json.loads(CORE_REFUSAL.replace(REFUSED_ID, request_id))
    return json.dumps({"http_status": 400, "body": body, "transport_attempts": 1,
                       "transport_retry_exits": []})


def approvals(n: int) -> list:
    """``n`` approve decisions, each citing the same precedent."""
    precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9999)}]
    return sd.plan(snapshot([row(i, precedent_key="k") for i in range(1, n + 1)],
                            precedent=precedent), now=NOW)


def refusing(calls: list):
    """A writer that answers every call the way production answered the drain."""
    def writer(d):
        calls.append(d.request_id)
        sd._assert_written(d, refusal_envelope(d.request_id))
    return writer


class WriteFailureTests(unittest.TestCase):
    """A failed write names its layer, stays on the ledger, and is not sent again blind.

    The 11 November run: 92,386 decisions applied, all 3,326 approvals failed, and what
    survived was one stderr line per row and rc=1. Every later run would have sent the
    same 3,326 refused calls again.
    """

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.dir = Path(td.name)
        self.db = sd.open_ledger(str(self.dir / "ledger.sqlite"))

    def _failures(self):
        return self.db.execute("SELECT request_id, layer, http_status, error_code, reasons"
                               " FROM write_failures ORDER BY id").fetchall()

    # ── the API's answer survives ────────────────────────────────────────────
    def test_the_production_refusal_keeps_its_code_and_reasons(self):
        d = dataclasses_replace(approvals(1)[0], request_id=REFUSED_ID)
        with self.assertRaises(sd.DrainWriteError) as ctx:
            sd._assert_written(d, refusal_envelope())
        exc = ctx.exception
        self.assertEqual((exc.layer, exc.http_status, exc.error_code),
                         ("api", 400, "agent_cannot_approve_declined"))
        self.assertEqual(exc.reasons, ("validator_not_approved", "no_registered_automation"))
        self.assertIsInstance(exc, sd.DrainRefusedByCore)
        self.assertEqual(exc.failure_class, "core_automation_not_registered")
        self.assertIn("core refused the approve with agent_cannot_approve_declined "
                      "(band=A_auto reasons=validator_not_approved,no_registered_automation)"
                      ": HTTP 400, nothing written", str(exc))

    def test_reasons_are_this_rows_not_a_neighbours(self):
        d = approvals(1)[0]
        with self.assertRaises(sd.DrainWriteError) as ctx:
            sd._assert_written(d, refusal_envelope())    # the body names another request
        self.assertEqual(ctx.exception.error_code, "agent_cannot_approve_declined")
        self.assertEqual(ctx.exception.reasons, ())

    def test_each_layer_is_named(self):
        d = approvals(1)[0]
        ok_other_row = json.dumps({"http_status": 200, "body": {"updatedIds": [rid(77)]}})
        cases = [("", "wrapper"), ("not json", "wrapper"),
                 (json.dumps({"http_status": 502, "raw": "<html>bad gateway</html>"}), "api"),
                 (json.dumps({"http_status": None, "body": None,
                              "transport_error": {"curl_exit": 28}}), "transport"),
                 (json.dumps({"http_status": 200, "body": {}}), "response"),
                 (ok_other_row, "response")]
        for stdout, layer in cases:
            with self.subTest(layer=layer, stdout=stdout[:30]):
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    sd._assert_written(d, stdout)
                self.assertEqual(ctx.exception.layer, layer)

    def test_a_missing_token_file_is_the_token_layer(self):
        """11 November, 18:41Z: the token file did not exist until 19:05Z."""
        spawned = []
        writer = sd.admin_writer("/nonexistent/wrapper.sh", runner=spawned.append,
                                 token_file=str(self.dir / "no-such-token"))
        with self.assertRaises(sd.DrainWriteError) as ctx:
            writer(approvals(1)[0])
        self.assertEqual(ctx.exception.layer, "token")
        self.assertEqual(spawned, [])

    def test_a_wrapper_exit_is_the_wrapper_layer_unless_the_call_left(self):
        token = self.dir / "token"
        token.write_text("t\n")
        d = approvals(1)[0]
        gate = subprocess.CompletedProcess([], 1, stdout="", stderr="MUSO_API_URL not set")
        left = subprocess.CompletedProcess(
            [], 28, stderr="", stdout='{"http_status":null,"body":null,'
                                      '"transport_error":{"curl_exit":28}}')
        for proc, layer in ((gate, "wrapper"), (left, "transport")):
            with self.subTest(layer=layer):
                writer = sd.admin_writer("w.sh", runner=lambda *a, proc=proc, **k: proc,
                                         token_file=str(token))
                with self.assertRaises(sd.DrainWriteError) as ctx:
                    writer(d)
                self.assertEqual(ctx.exception.layer, layer)

    # ── the ledger keeps it ──────────────────────────────────────────────────
    def test_a_refusal_is_recorded_with_what_the_api_said(self):
        decisions = approvals(1)
        stats = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=refusing([]))
        self.assertEqual(self._failures(), [
            (rid(1), "api", 400, "agent_cannot_approve_declined",
             '["validator_not_approved", "no_registered_automation"]')])
        self.assertEqual(stats["failures"], {"api/agent_cannot_approve_declined": 1})
        self.assertEqual((stats["errors"], stats["applied"]), (1, 0))
        self.assertEqual(self.db.execute("SELECT state FROM intents").fetchall(), [("planned",)])

    def test_the_failure_log_is_append_only(self):
        sd.apply(approvals(1), self.db, shards=1, write_pool=1, writer=refusing([]))
        for sql in ("UPDATE write_failures SET layer = 'x'", "DELETE FROM write_failures"):
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute(sql)

    # ── and the next run does not send it again ──────────────────────────────
    def test_a_refused_row_is_held_with_no_read_and_no_write(self):
        decisions = approvals(3)
        calls, reads = [], []

        def reconciler(d, planned_at):
            reads.append(d.request_id)
            return sd.NOT_LANDED

        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=refusing(calls))
        self.assertEqual(len(calls), 3)
        again = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=refusing(calls),
                         reconciler=reconciler)
        self.assertEqual((len(calls), reads), (3, []))
        self.assertEqual((again["refused_held"], again["attempted"], again["errors"]), (3, 0, 0))
        self.assertEqual(len(self._failures()), 3)

    def test_a_redrive_is_bounded_by_its_number(self):
        decisions = approvals(5)
        calls = []
        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=refusing(calls))
        del calls[:]
        granted = []
        stats = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=granted.append,
                         reconciler=lambda d, planned_at: sd.NOT_LANDED, redrive_refused=2)
        self.assertEqual([d.request_id for d in granted], [rid(1), rid(2)])
        self.assertEqual((stats["redriven"], stats["applied"], stats["refused_held"]), (2, 2, 3))
        self.assertEqual(sd.failure_summary(self.db)["held_refusals"], 3)

    def test_a_failure_that_is_not_a_verdict_keeps_the_read_then_retry_path(self):
        """A timeout or a 5xx says nothing about the row: it is read, then retried."""
        decisions = approvals(1)
        outage = json.dumps({"http_status": 503, "body": {"errorCode": "unavailable"}})
        calls = []

        def writer(d):
            calls.append(d.request_id)
            if len(calls) == 1:
                sd._assert_written(d, outage)

        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual(self._failures()[0][1:4], ("api", 503, "unavailable"))
        stats = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer,
                         reconciler=lambda d, planned_at: sd.NOT_LANDED)
        self.assertEqual((len(calls), stats["applied"], stats["refused_held"]), (2, 1, 0))

    def test_a_throttle_or_an_expired_session_is_never_a_durable_refusal(self):
        """429/408/425 and 401/403 are the run's condition, not the row's. Held, a single
        throttle would turn into a refusal to send that only ``--redrive-refused`` could
        undo: the row keeps the read-then-retry path."""
        for status in sd.NOT_A_ROW_VERDICT:
            with self.subTest(status=status):
                d = approvals(1)[0]
                db = sd.open_ledger(str(self.dir / f"retry-{status}.sqlite"))
                envelope = json.dumps({"http_status": status,
                                       "body": {"errorCode": "rate_limited"}})
                calls = []

                def writer(decision, envelope=envelope, calls=calls):
                    calls.append(decision.request_id)
                    if len(calls) == 1:
                        sd._assert_written(decision, envelope)

                sd.apply([d], db, shards=1, write_pool=1, writer=writer)
                self.assertFalse(sd.is_refusal(sd.last_failure(db, d.decision_key)))
                again = sd.apply([d], db, shards=1, write_pool=1, writer=writer,
                                 reconciler=lambda decision, at: sd.NOT_LANDED)
                self.assertEqual((len(calls), again["applied"], again["refused_held"]),
                                 (2, 1, 0))

    # ── a row core judged is not an approve in flight ────────────────────────
    def _row_refused(self, *reasons):
        """A writer whose API refusal names core's own reasons for the row."""
        def writer(d):
            body = json.loads(refusal_envelope(d.request_id))
            body["body"]["refused"][0]["reasons"] = list(reasons)
            sd._assert_written(d, json.dumps(body))
        return writer

    def _core_refusals(self):
        return self.db.execute("SELECT request_id, reason, outcome, route FROM core_refusals"
                               " ORDER BY id").fetchall()

    def test_an_approve_core_refused_keeps_cores_reason_as_its_outcome(self):
        sd.apply(approvals(1), self.db, shards=1, write_pool=1,
                 writer=self._row_refused("proof_required"))
        self.assertEqual(self._core_refusals(),
                         [(rid(1), "proof_required", "refused_by_core:proof_required", "ask")])

    def test_a_proof_or_precedent_refusal_goes_to_the_ask_path_not_a_person(self):
        """Core naming a document or an unsound precedent is answered by asking, and the
        ONE reviewed ask path is what asks: the drain emits the selection, the customer
        gets the ask, and no tier-2 queue grows for these rows."""
        def writer(d):
            reason = "proof_required" if d.request_id == rid(1) else "no_sound_precedent"
            self._row_refused(reason)(d)

        decisions = approvals(2)
        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual([(r[0], r[3]) for r in self._core_refusals()],
                         [(rid(1), "ask"), (rid(2), "ask")])
        self.assertEqual([(a["request_id"], a["user_id"], a["outcome"])
                          for a in sd.refused_asks(self.db)],
                         [(rid(1), 1001, "ask"), (rid(2), 1002, "ask")])
        plan = self.dir / "plan.jsonl"
        plan.write_bytes(sd.serialize(decisions))
        audience = self.dir / "asks.jsonl"
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            rc = sd._main(["asks", "--plan", str(plan), "--ledger",
                           str(self.dir / "ledger.sqlite"), "--out", str(audience)])
        self.assertEqual(rc, 0)
        self.assertEqual(na.drain_asks(str(audience)),
                         {(1001, rid(1)), (1002, rid(2))})
        # and the second run does not pretend they are held refusals
        again = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual((again["refused_to_ask"], again["refused_held"], again["attempted"]),
                         (2, 0, 0))

    def test_a_ladder_ask_row_held_for_a_cause_no_document_clears_is_not_offered_to_the_ask_path(self):
        """The ladder's own ask bucket is the larger channel (91,229 of 96,703 rows): a
        request the validator holds for fraud, impersonation or another band C cause must
        not reach the need-ask audience just because no ladder rule matched it."""
        table = json.loads(policy.BANDS_PATH.read_text())
        velocity = sorted(sd.velocity_hold_causes())[0]
        rows = [row(1),                                                         # no verdict read: asked
                row(2, hold_causes=[]),                                         # holds nothing: asked
                row(3, hold_causes=["review_big_track_without_trusted_credit"]),  # a document answers it
                row(4, hold_causes=["fraud_hold"]),
                row(5, hold_causes=["review_role_credited_to_other_at_trusted_source"]),
                row(6, hold_causes=["reject_publisher_label_credit"]),
                row(7, hold_causes=["review_big_track_without_trusted_credit", "validation_error"]),
                row(8, hold_causes=[velocity], claimed_roles=["Mixing"]),
                row(9, hold_causes=[velocity], claimed_roles=[table["high_risk_roles"]["catalog_children"][0]])]
        decisions = sd.plan(snapshot(rows), now=NOW)
        self.assertEqual({d.outcome for d in decisions}, {"ask"})
        offered, held = sd.split_asks(decisions)
        self.assertEqual([d.request_id for d in offered], [rid(1), rid(2), rid(3), rid(9)])
        self.assertEqual([(d.request_id, why) for d, why in held], [
            (rid(4), "fraud:fraud_hold"),
            (rid(5), "impersonation:review_role_credited_to_other_at_trusted_source"),
            (rid(6), "band_c:reject_publisher_label_credit"),
            (rid(7), "unmeasured:validation_error"),
            (rid(8), f"band_c_velocity:{velocity}")])
        plan = self.dir / "plan.jsonl"
        plan.write_bytes(sd.serialize(decisions))
        audience = self.dir / "asks.jsonl"
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            rc = sd._main(["asks", "--plan", str(plan), "--ledger",
                           str(self.dir / "ledger.sqlite"), "--out", str(audience)])
        self.assertEqual(rc, 0)
        self.assertEqual(na.drain_asks(str(audience)),
                         {(1001, rid(1)), (1002, rid(2)), (1003, rid(3)), (1009, rid(9))})
        said = json.loads(err.getvalue().strip().splitlines()[-1])
        self.assertEqual((said["held_never_asked"], said["held_never_asked_users"]), (5, 5))
        self.assertEqual(said["held_by_class"],
                         {"band_c": 1, "band_c_velocity": 1, "fraud": 1, "impersonation": 1, "unmeasured": 1})

    def test_a_plan_written_before_ask_rows_carried_causes_offers_them_as_before(self):
        """An old plan names no cause on an ask row: unmeasured is asked, as it always
        was, so the deploy does not silently empty the audience of a plan in flight."""
        decisions = sd.plan(snapshot([row(1, hold_causes=["fraud_hold"])]), now=NOW)
        old = [json.loads(line) for line in sd.serialize(decisions).splitlines()]
        for r in old:
            r.pop("hold_causes", None), r.pop("editing_burst", None)
        again = sd.parse_plan("\n".join(json.dumps(r) for r in old).encode() + b"\n")
        offered, held = sd.split_asks(again)
        self.assertEqual(([d.request_id for d in offered], held), ([rid(1)], []))

    def test_a_validator_hold_stays_held_and_is_not_asked(self):
        sd.apply(approvals(1), self.db, shards=1, write_pool=1,
                 writer=self._row_refused("validator_hold", "proof_required"))
        self.assertEqual(self._core_refusals()[0][1:], ("validator_hold",
                                                        "refused_by_core:validator_hold",
                                                        "hold"))
        self.assertEqual(sd.refused_asks(self.db), [])
        self.assertEqual(sd.failure_summary(self.db)["held_refusals"], 1)

    def _held_with(self, causes, *reasons, editing_burst=None):
        """One approve whose snapshot says the validator holds it for ``causes``, refused
        by core with ``reasons``; returns (reason, outcome, route, hold_note)."""
        (d,) = approvals(1)
        d = dataclasses_replace(d, hold_causes=causes, editing_burst=editing_burst)
        sd.apply([d], self.db, shards=1, write_pool=1, writer=self._row_refused(*reasons))
        return self.db.execute("SELECT reason, outcome, route, hold_note FROM core_refusals"
                               " ORDER BY id DESC LIMIT 1").fetchone()

    def test_a_proof_refusal_is_asked_when_the_hold_beside_it_is_one_a_document_answers(self):
        """Core lists ``validator_hold`` first on a proof row, so holding on that word
        alone held rows whose only open question was the document (2026-11-14)."""
        got = self._held_with(("review_big_track_without_trusted_credit",),
                              "proof_required", "validator_hold", "high_risk_score")
        self.assertEqual(got, ("proof_required", "refused_by_core:proof_required", "ask",
                               "askable:review_big_track_without_trusted_credit"))
        self.assertEqual([(a["request_id"], a["outcome"], a["reason_code"])
                          for a in sd.refused_asks(self.db)],
                         [(rid(1), "ask", "refused_by_core:proof_required")])

    def test_a_velocity_hold_is_asked_only_on_an_editing_burst(self):
        """The bands make a velocity hold band B only when an editing role was held
        (``editing_burst_rules``); on any other role it is band C, which no document
        clears, and roles that could not be read are not measured."""
        for cause in sorted(sd.velocity_hold_causes()):
            with self.subTest(cause=cause, case="editing"):
                self.setUp()
                got = self._held_with((cause,), "proof_required", "validator_hold",
                                      editing_burst=True)
                self.assertEqual(got, ("proof_required", "refused_by_core:proof_required",
                                       "ask", f"askable:{cause}"))
            with self.subTest(cause=cause, case="not editing"):
                self.setUp()
                got = self._held_with((cause,), "proof_required", "validator_hold",
                                      editing_burst=False)
                self.assertEqual(got, ("validator_hold", "refused_by_core:validator_hold",
                                       "hold", f"band_c_velocity:{cause}"))
                self.assertEqual(sd.refused_asks(self.db), [])
            with self.subTest(cause=cause, case="roles unread"):
                self.setUp()
                got = self._held_with((cause,), "proof_required", "validator_hold",
                                      editing_burst=None)
                self.assertEqual(got, ("validator_hold", "refused_by_core:validator_hold",
                                       "hold", f"velocity_roles_unmeasured:{cause}"))

    def test_the_editing_burst_is_read_from_the_bands_not_a_copy_of_the_roles(self):
        bands = json.loads((SCRIPTS / "credit_trust/credit_trust_bands.json").read_text())
        high = bands["high_risk_roles"]
        for role in list(high["catalog_children"]) + ["Editor", "Vocal Editing", "Compilation"]:
            with self.subTest(role=role):
                self.assertTrue(sd.editing_burst([role]), role)
        for role in ("Mastering", "Mixing", "Producer", "Immersive Mixing"):
            with self.subTest(role=role):
                self.assertFalse(sd.editing_burst([role]), role)
        self.assertIsNone(sd.editing_burst([]))
        self.assertIsNone(sd.editing_burst(None))

    def test_the_editing_burst_rides_the_plan_and_survives_a_round_trip(self):
        velocity = sorted(sd.velocity_hold_causes())[0]
        precedent = [{"precedent_key": "k", "outcome": "approve", "request_id": rid(9999)}]
        db = snapshot([row(1, precedent_key="k", hold_causes=[velocity],
                           claimed_roles=["Editor"]),
                       row(2, precedent_key="k", hold_causes=[velocity],
                           claimed_roles=["Mastering"]),
                       row(3, precedent_key="k", hold_causes=[velocity]),
                       row(4, precedent_key="k", hold_causes=["class_c"],
                           claimed_roles=["Editor"])],
                      precedent=precedent)
        decisions = sd.plan(db, now=NOW)
        self.assertEqual([d.editing_burst for d in decisions], [True, False, None, None])
        again = sd.parse_plan(sd.serialize(decisions))
        self.assertEqual([d.editing_burst for d in again], [True, False, None, None])
        self.assertEqual(sd.serialize(again), sd.serialize(decisions))

    def test_every_askable_hold_cause_alone_or_together_is_asked(self):
        for causes in [(c,) for c in sorted(sd.ASKABLE_HOLD_CAUSES)] + [
                tuple(sorted(sd.ASKABLE_HOLD_CAUSES))]:
            with self.subTest(causes=causes):
                self.setUp()
                self.assertEqual(self._held_with(causes, "validator_hold", "proof_required")[2],
                                 "ask")

    def test_a_hard_hold_is_never_asked_even_beside_a_proof_reason(self):
        """Fraud, impersonation and legal holds, a credit the profile already has and a
        check that could not complete stay held: the document does not answer them."""
        want = {"review_held_submitter": "fraud", "fraud_hold": "fraud",
                "review_role_credited_to_other_at_trusted_source": "impersonation",
                "review_operations_tombstone": "legal",
                "review_duplicate_of_approved_credit": "already_held",
                "_hold_on_error": "unmeasured"}
        self.assertEqual(sd.HARD_HOLD_CAUSES, want)
        for cause, kind in want.items():
            # alone, and layered under a cause that would otherwise be asked
            for causes in ((cause,), ("review_big_track_without_trusted_credit", cause)):
                with self.subTest(causes=causes):
                    self.setUp()
                    got = self._held_with(causes, "proof_required", "validator_hold")
                    self.assertEqual(got, ("validator_hold", "refused_by_core:validator_hold",
                                           "hold", f"{kind}:{cause}"))
                    self.assertEqual(sd.refused_asks(self.db), [])

    def test_fraud_then_impersonation_is_the_cause_named_on_a_row_with_several(self):
        """A row can carry several never-asked causes and one is named. A sender that holds
        an account reads the class of that one, so it is fraud, then impersonation, before
        any cause whose name merely sorts first."""
        impersonation, submitter = "review_role_credited_to_other_at_trusted_source", "review_held_submitter"
        for causes, note in (
                (("reject_publisher_label_credit", impersonation), f"impersonation:{impersonation}"),
                (("reject_publisher_label_credit", submitter), f"fraud:{submitter}"),
                (("review_duplicate_of_approved_credit", impersonation), f"impersonation:{impersonation}"),
                (("reject_artist_credit", impersonation, submitter), f"fraud:{submitter}"),
                (("reject_artist_credit", "reject_publisher_label_credit"), "band_c:reject_artist_credit")):
            with self.subTest(causes=causes):
                self.assertEqual(sd.never_asked_cause(causes), note)
                self.assertEqual(sd.never_asked_cause(tuple(reversed(causes))), note)
                self.setUp()
                got = self._held_with(causes, "proof_required", "validator_hold")
                self.assertEqual(got[2:], ("hold", note))

    def test_a_hold_whose_cause_was_not_measured_or_not_classified_stays_held(self):
        """Unmeasured is not an ask: no cause on the plan row, a hold core reports that the
        snapshot does not show, and a rule this code has never seen all hold."""
        for causes, note in ((None, "hold_cause_unmeasured"),
                             ((), "hold_cause_not_in_snapshot"),
                             (("review_a_rule_added_later",), "unclassified:review_a_rule_added_later"),
                             (("review_big_track_weak_footprint", "review_a_rule_added_later"),
                              "unclassified:review_a_rule_added_later")):
            with self.subTest(causes=causes):
                self.setUp()
                got = self._held_with(causes, "proof_required", "validator_hold")
                self.assertEqual((got[2], got[3]), ("hold", note))

    def test_the_hold_cause_changes_nothing_when_core_named_no_ask_reason(self):
        """An askable cause never turns a row core did not put on the ask path into an ask."""
        got = self._held_with(("review_big_track_without_trusted_credit",),
                              "validator_hold", "reject_rule")
        self.assertEqual(got[:3], ("validator_hold", "refused_by_core:validator_hold", "hold"))

    def test_a_proof_refusal_with_no_validator_hold_is_asked_unless_a_cause_no_document_clears(self):
        """Core did not hold it, so an askable, unmeasured or missing cause is not
        consulted - a stale cause must not hold a row core says is only waiting on a
        document. A band C or hard cause still holds: core says ``validator_hold`` only
        for its own ``review_*`` reading, so a ``reject_*`` rule arrives with no word from
        core, and the ask would be one no document can clear."""
        for causes in (("review_big_track_without_trusted_credit",), None, (),
                       ("review_a_rule_added_later",)):
            with self.subTest(causes=causes):
                self.setUp()
                got = self._held_with(causes, "proof_required", "high_risk_score")
                self.assertEqual(got, ("proof_required", "refused_by_core:proof_required",
                                       "ask", None))
        for causes, note in ((("reject_publisher_label_credit",),
                              "band_c:reject_publisher_label_credit"),
                             (("validation_error",), "unmeasured:validation_error"),
                             (("review_held_submitter",), "fraud:review_held_submitter"),
                             (("fraud_hold",), "fraud:fraud_hold"),
                             (("reject_deleted_catalog_track",
                               "review_big_track_without_trusted_credit"),
                              "band_c:reject_deleted_catalog_track")):
            with self.subTest(causes=causes):
                self.setUp()
                got = self._held_with(causes, "proof_required", "high_risk_score")
                # the outcome keeps core's own reason; the note says what holds the row
                self.assertEqual(got, ("proof_required", "refused_by_core:proof_required",
                                       "hold", note))
                self.assertEqual(sd.refused_asks(self.db), [])
                self.assertEqual(sd.failure_summary(self.db)["held_refusals"], 1)

    def test_a_band_c_cause_under_an_askable_hold_is_never_asked(self):
        """The mixed case: a hold a document answers, with a band C cause beneath it.
        Every cause of the band table holds, alone or layered, with or without core's
        ``validator_hold``; the velocity rules keep their one editing-burst exception."""
        bands = json.loads((SCRIPTS / "credit_trust/credit_trust_bands.json").read_text())
        errors = set(bands["band_c_error_keys"])
        table = (set(bands["band_c_rules"]) | errors) - set(sd.velocity_hold_causes())
        self.assertGreaterEqual(len(table), 12)
        for cause in sorted(table):
            kind = sd.HARD_HOLD_CAUSES.get(cause) or (
                "unmeasured" if cause in errors else "band_c")
            self.assertEqual(sd.hold_class(cause), kind)
            for causes in ((cause,), ("review_big_track_without_trusted_credit", cause),
                           ("class_c", "review_hold_for_documents", cause)):
                for reasons in (("proof_required", "validator_hold"),
                                ("no_sound_precedent", "validator_hold"),
                                ("proof_required",)):
                    with self.subTest(causes=causes, reasons=reasons):
                        self.setUp()
                        got = self._held_with(causes, *reasons)
                        self.assertEqual((got[2], got[3]), ("hold", f"{kind}:{cause}"))
                        self.assertEqual(sd.refused_asks(self.db), [])
        # the same askable causes with no band C beneath them are still asked
        self.setUp()
        got = self._held_with(("class_c", "review_hold_for_documents"),
                              "proof_required", "validator_hold")
        self.assertEqual((got[2], got[3]), ("ask", "askable:class_c,review_hold_for_documents"))

    def test_a_velocity_hold_with_no_word_from_core_keeps_its_editing_exception(self):
        for cause in sorted(sd.velocity_hold_causes()):
            for burst, want in ((True, ("ask", None)),
                                (False, ("hold", f"band_c_velocity:{cause}")),
                                (None, ("hold", f"velocity_roles_unmeasured:{cause}"))):
                with self.subTest(cause=cause, burst=burst):
                    self.setUp()
                    got = self._held_with((cause,), "proof_required", editing_burst=burst)
                    self.assertEqual((got[2], got[3]), want)

    def test_every_review_rule_the_validator_can_fire_is_classified_once(self):
        """A rule IDP adds later must fail here until someone says ask or hold for it."""
        bands = json.loads((SCRIPTS / "credit_trust/credit_trust_bands.json").read_text())
        known: set[str] = set()

        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if str(k).startswith("review_"):
                        known.add(k)
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
            elif isinstance(node, str) and node.startswith("review_"):
                known.add(node)
        walk(bands)
        self.assertGreaterEqual(len(known), 14)
        band_c = set(sd.band_c_causes())
        classified = (set(sd.ASKABLE_HOLD_CAUSES) | set(sd.HARD_HOLD_CAUSES)
                      | set(sd.velocity_hold_causes()) | band_c)
        self.assertEqual(known - classified, set())
        # nothing the band table calls band C is on the list a document answers
        self.assertEqual(set(sd.ASKABLE_HOLD_CAUSES) & band_c, set())
        # every review_ rule this file names hard is band C in the table too
        self.assertLessEqual({c for c in sd.HARD_HOLD_CAUSES if c.startswith("review_")}, band_c)
        self.assertEqual(set(sd.ASKABLE_HOLD_CAUSES) & set(sd.HARD_HOLD_CAUSES), set())
        self.assertEqual(set(sd.velocity_hold_causes()) & (
            set(sd.ASKABLE_HOLD_CAUSES) | set(sd.HARD_HOLD_CAUSES)), set())
        # the bands' own velocity rules are the ones asked only on an editing burst
        self.assertEqual(set(sd.velocity_hold_causes()),
                         set(bands["proof_required"]["editing_burst_rules"]))
        # the validator's own "ask the claimant" rules are all askable here
        self.assertLessEqual(set(bands["proof_required"]["rules"]), set(sd.ASKABLE_HOLD_CAUSES))

    def test_a_ledger_made_before_the_hold_note_gains_the_column(self):
        path = str(self.dir / "old.sqlite")
        old = sqlite3.connect(path)
        old.execute("CREATE TABLE core_refusals (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                    " decision_key TEXT NOT NULL, request_id TEXT NOT NULL, user_id INTEGER,"
                    " reason TEXT NOT NULL, outcome TEXT NOT NULL,"
                    " route TEXT NOT NULL CHECK (route IN ('ask', 'hold')), refused_at TEXT NOT NULL)")
        old.execute("INSERT INTO core_refusals (decision_key, request_id, reason, outcome, route,"
                    " refused_at) VALUES ('k', 'r', 'validator_hold', 'refused_by_core:validator_hold',"
                    " 'hold', '2026-11-13T00:00:00.000000Z')")
        old.commit()
        old.close()
        db = sd.open_ledger(path)
        self.assertEqual(db.execute("SELECT route, hold_note FROM core_refusals").fetchall(),
                         [("hold", None)])
        db.close()

    def test_a_refusal_whose_route_could_not_be_recorded_is_never_called_an_ask(self):
        """The route has ONE source: the recorded refusal. With no row saying "ask", the
        row is held, because the ask selection would not name it."""
        d = approvals(1)[0]
        with mock.patch.object(sd, "_record_core_refusal",
                               side_effect=sqlite3.Error("disk I/O error")), \
                contextlib.redirect_stderr(io.StringIO()):
            first = sd.apply([d], self.db, shards=1, write_pool=1,
                             writer=self._row_refused("proof_required"))
        self.assertEqual((first["held_by_core"], first["errors"]), (1, 1))
        self.assertEqual(first["stop_reason"], "ledger")
        self.assertEqual(sd.refused_asks(self.db), [])
        again = sd.apply([d], self.db, shards=1, write_pool=1,
                         writer=self._row_refused("proof_required"))
        self.assertEqual((again["refused_to_ask"], again["refused_held"],
                          again["attempted"]), (0, 1, 0))
        self.assertEqual(sd.failure_summary(self.db)["routed_to_ask"], 0)

    def test_a_refusal_the_ledger_cannot_keep_stops_the_run_before_the_next_send(self):
        """An unrecorded refusal has no ask route, so every later approve this run sends
        is a grant whose refusal nobody will ever ask about. The run stops instead."""
        calls = []

        def writer(d):
            calls.append(d.request_id)
            self._row_refused("proof_required")(d)

        with mock.patch.object(sd, "_record_core_refusal",
                               side_effect=sqlite3.Error("disk I/O error")), \
                contextlib.redirect_stderr(io.StringIO()):
            stats = sd.apply(approvals(3), self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual((len(calls), stats["attempted"], stats["stopped"]), (1, 1, True))
        self.assertEqual((stats["stop_reason"], stats["error_classes"]),
                         ("ledger", {"core_row_refused": 1, "ledger_error": 1}))

    def test_the_run_that_discovers_core_refusals_exits_zero(self):
        """The pass that MEETS the refusals: expected refusals are not errors, and the
        only thing this run did not write is rows held by design or waiting on an ask."""
        plan = self.dir / "plan.jsonl"
        plan.write_bytes(sd.serialize(approvals(3)))
        ledger = str(self.dir / "discover.sqlite")

        def writer(d):
            reason = "proof_required" if d.request_id == rid(1) else "validator_hold"
            self._row_refused(reason)(d)

        rc, out, err = self._run_cli("apply", "--plan", str(plan), "--ledger", ledger,
                                     "--write-pool", "1", writer=writer)
        stats = json.loads(out)
        self.assertEqual((rc, stats["errors"], stats["held_by_core"]), (0, 0, 3))
        self.assertNotIn("APPLY INCOMPLETE", err)
        rc, out, err = self._run_cli("apply", "--plan", str(plan), "--ledger", ledger,
                                     "--write-pool", "1", writer=writer)
        stats = json.loads(out)
        self.assertEqual((rc, stats["attempted"], stats["refused_to_ask"],
                          stats["refused_held"]), (0, 0, 1, 2))
        self.assertNotIn("APPLY INCOMPLETE", err)

    def test_a_missing_registration_is_still_an_incomplete_run(self):
        plan = self.dir / "reg-plan.jsonl"
        plan.write_bytes(sd.serialize(approvals(1)))
        rc, out, err = self._run_cli("apply", "--plan", str(plan),
                                     "--ledger", str(self.dir / "reg.sqlite"),
                                     "--write-pool", "1", writer=refusing([]))
        stats = json.loads(out)
        self.assertEqual((rc, stats["errors"], stats["held_by_core"]), (1, 1, 0))
        self.assertIn("APPLY INCOMPLETE", err)

    # ── a path that only fails is stopped ────────────────────────────────────
    def test_ten_failures_in_a_row_stop_the_run(self):
        calls = []
        stats = sd.apply(approvals(40), self.db, shards=4, write_pool=1, writer=refusing(calls))
        self.assertEqual(len(calls), sd.BREAKER)
        self.assertEqual(stats["stop_reason"], "breaker")
        self.assertEqual(stats["breaker"], {"failures_in_a_row": 10,
                                            "last": "api/agent_cannot_approve_declined"})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 10)

    def test_the_breaker_bounds_a_parallel_run_too(self):
        calls = []
        sd.apply(approvals(120), self.db, shards=16, write_pool=6, writer=refusing(calls))
        self.assertGreaterEqual(len(calls), sd.BREAKER)
        self.assertLess(len(calls), sd.BREAKER + 6)     # at most the calls already in flight

    def test_a_success_resets_the_breaker(self):
        calls = []

        def writer(d):
            calls.append(d.request_id)
            if len(calls) % 5:                          # four failures, then a success
                sd._assert_written(d, refusal_envelope(d.request_id))

        stats = sd.apply(approvals(40), self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual((len(calls), stats["applied"], stats["stopped"]), (40, 8, False))

    def test_rows_core_judged_do_not_trip_the_breaker_and_are_not_sent_again(self):
        """The registered drain against the real backlog: core refuses most rows on
        their own facts and grants the rest. That is the path working, so it must not
        stop a batch of 25 at the tenth refusal - and no refused row is sent twice."""
        calls = []

        def writer(d):
            calls.append(d.request_id)
            body = json.loads(refusal_envelope(d.request_id))
            body["body"]["refused"][0]["reasons"] = ["validator_hold"]
            sd._assert_written(d, json.dumps(body))

        decisions = approvals(25)
        stats = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual((len(calls), stats["applied"], stats["stopped"]), (25, 0, False))
        self.assertEqual(stats["error_classes"], {"core_row_refused": 25})
        self.assertNotIn("breaker", stats)
        again = sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        self.assertEqual((len(calls), again["refused_held"]), (25, 25))   # no second call

    # ── a bounded batch ──────────────────────────────────────────────────────
    def test_max_writes_is_a_hard_bound_and_leaves_no_stray_intent(self):
        decisions = approvals(40)
        calls = []
        stats = sd.apply(decisions, self.db, shards=4, write_pool=1, writer=calls.append,
                         max_writes=25)
        self.assertEqual((len(calls), stats["applied"], stats["stop_reason"]),
                         (25, 25, "max_writes"))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 25)
        rest = sd.apply(decisions, self.db, shards=4, write_pool=1, writer=calls.append)
        self.assertEqual((len(calls), rest["applied"], rest["skipped"]), (40, 15, 25))

    def test_max_writes_holds_under_a_parallel_pool(self):
        """Six workers each read a slow open intent before writing: the bound is taken
        when the call STARTS, so the ones still reading cannot carry it past 25."""
        decisions = approvals(120)

        def down(d):
            raise sd.DrainWriteError("timeout", layer="transport")

        sd.apply(decisions, self.db, shards=16, write_pool=6, writer=down, breaker=None)
        calls = []

        def slow_read(d, planned_at):
            time.sleep(0.005)
            return sd.NOT_LANDED

        stats = sd.apply(decisions, self.db, shards=16, write_pool=6, writer=calls.append,
                         reconciler=slow_read, max_writes=25)
        self.assertEqual((len(calls), stats["attempted"], stats["applied"]), (25, 25, 25))

    # ── a 2xx is not a granted credit ────────────────────────────────────────
    def test_a_write_that_does_not_read_back_is_not_confirmed(self):
        decisions = approvals(1)
        told = []
        for answer in (lambda d, at: sd.NOT_LANDED, lambda d, at: 1 / 0):
            with self.subTest(answer=answer):
                db = sd.open_ledger(str(self.dir / f"rb-{len(told)}.sqlite"))
                stats = sd.apply(decisions, db, shards=1, write_pool=1,
                                 writer=lambda d: None, readback=answer, report=told.append)
                self.assertEqual((stats["applied"], stats["errors"]), (0, 1))
                self.assertEqual(stats["failures"], {"readback/-": 1})
                self.assertEqual(db.execute("SELECT state FROM intents").fetchall(),
                                 [("planned",)])
                self.assertEqual(told[-1]["result"], "failed")
                # the next run reads the request again, and only then says it is done
                later = sd.apply(decisions, db, shards=1, write_pool=1, writer=lambda d: 1 / 0,
                                 reconciler=lambda d, at: sd.LANDED)
                self.assertEqual((later["reconciled"], later["attempted"]), (1, 0))

    def test_granted_means_read_back(self):
        decisions = approvals(2)
        seen, told = [], []

        def readback(d, planned_at):
            seen.append((d.request_id, planned_at))
            return sd.LANDED

        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=lambda d: None,
                 readback=readback, report=told.append)
        planned = dict(self.db.execute("SELECT request_id, planned_at FROM intents"))
        self.assertEqual(seen, [(rid(1), planned[rid(1)]), (rid(2), planned[rid(2)])])
        self.assertEqual([(t["request_id"], t["user_id"], t["result"]) for t in told],
                         [(rid(1), 1001, "granted"), (rid(2), 1002, "granted")])
        unread = []
        sd.apply(approvals(1), sd.open_ledger(str(self.dir / "u.sqlite")), shards=1,
                 write_pool=1, writer=lambda d: None, report=unread.append)
        self.assertEqual(unread[0]["result"], "written_unread")

    # ── one grant per request, whatever is run again ─────────────────────────
    def test_a_granted_request_is_never_written_twice(self):
        decisions = approvals(30)
        calls = []
        kw = dict(shards=4, write_pool=6, writer=lambda d: calls.append(d.request_id),
                  readback=lambda d, at: sd.LANDED, reconciler=lambda d, at: sd.NOT_LANDED)
        sd.apply(decisions, self.db, max_writes=25, **kw)
        for _ in range(3):      # the same plan again, with every re-drive lever pulled
            sd.apply(decisions, self.db, redrive_refused=1000, **kw)
        self.assertEqual(sorted(calls), sorted(d.request_id for d in decisions))
        self.assertEqual(len(set(calls)), 30)
        keys = self.db.execute("SELECT COUNT(*), COUNT(DISTINCT decision_key),"
                               " COUNT(DISTINCT request_id) FROM applied").fetchone()
        self.assertEqual(keys, (30, 30, 30))
        self.assertTrue(sd.verify(decisions, self.db)["ok"])

    # ── how many, and why ────────────────────────────────────────────────────
    def test_the_summary_counts_what_is_still_not_done_by_reason(self):
        decisions = approvals(4)
        calls = []

        def writer(d):
            calls.append(d.request_id)
            if d.request_id == rid(4):
                raise sd.DrainWriteError("no token", layer="token")
            sd._assert_written(d, refusal_envelope(d.request_id))

        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=writer)
        sd.apply(decisions, self.db, shards=1, write_pool=1, writer=lambda d: None,
                 reconciler=lambda d, at: sd.NOT_LANDED, redrive_refused=1)
        summary = sd.failure_summary(self.db)
        self.assertEqual(summary["by_reason"], {
            "api/400/agent_cannot_approve_declined/"
            "validator_not_approved+no_registered_automation": 2})
        self.assertEqual((summary["open_with_a_recorded_failure"], summary["held_refusals"],
                          summary["open_with_no_recorded_failure"]), (2, 2, 0))
        self.assertEqual([r["request_id"] for r in summary["rows"]], [rid(2), rid(3)])

    def test_an_intent_from_before_the_failure_log_is_counted_as_never_tried(self):
        """The 3,326 on node-8: planned on 11 November, with no failure row at all."""
        d = approvals(1)[0]
        sd._record_intent(self.db, d, 0, NOW)
        summary = sd.failure_summary(self.db)
        self.assertEqual((summary["open_with_no_recorded_failure"],
                          summary["open_with_a_recorded_failure"]), (1, 0))

    # ── the CLI never exits 1 in silence ─────────────────────────────────────
    def _run_cli(self, *argv, writer):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sd, "admin_writer", lambda script: writer), \
                mock.patch.object(sd, "admin_preflight", lambda script=None, **kw: []), \
                mock.patch.object(sd, "live_reconciler", lambda: (lambda d, at: sd.NOT_LANDED)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = sd._main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_apply_says_why_it_failed_and_lists_each_user(self):
        plan = self.dir / "plan.jsonl"
        plan.write_bytes(sd.serialize(approvals(12)))
        ledger, report = str(self.dir / "cli.sqlite"), self.dir / "report.jsonl"
        rc, out, err = self._run_cli("apply", "--plan", str(plan), "--ledger", ledger,
                                     "--write-pool", "1", "--report", str(report),
                                     writer=refusing([]))
        self.assertEqual(rc, 1)
        stats = json.loads(out)
        self.assertEqual((stats["attempted"], stats["stop_reason"]), (10, "breaker"))
        line = [ln for ln in err.splitlines() if ln.startswith("APPLY INCOMPLETE: ")]
        self.assertEqual(len(line), 1)
        self.assertIn('"api/agent_cannot_approve_declined": 10', line[0])
        rows = [json.loads(ln) for ln in report.read_text().splitlines()]
        self.assertEqual([(r["user_id"], r["result"], r["error_code"]) for r in rows],
                         [(1000 + i, "failed", "agent_cannot_approve_declined")
                          for i in range(1, 11)])
        # a held row is the drain working: printed in the stats, not an incomplete run
        held_plan = self.dir / "held.jsonl"
        held_plan.write_bytes(sd.serialize(approvals(10)))
        held_ledger = str(self.dir / "held.sqlite")
        first, out, _ = self._run_cli("apply", "--plan", str(held_plan), "--ledger",
                                      held_ledger, "--write-pool", "1", writer=refusing([]))
        self.assertEqual((first, json.loads(out)["refused_held"]), (1, 0))
        rc, out, err = self._run_cli("apply", "--plan", str(held_plan), "--ledger",
                                     held_ledger, "--write-pool", "1", writer=refusing([]))
        self.assertEqual((rc, json.loads(out)["refused_held"], json.loads(out)["attempted"]),
                         (0, 10, 0))
        self.assertNotIn("APPLY INCOMPLETE", err)
        rc, out, _ = self._run_cli("failures", "--ledger", held_ledger, writer=None)
        self.assertEqual((rc, json.loads(out)["held_refusals"]), (0, 10))
        self.assertNotIn("rows", json.loads(out))

    def test_a_clean_bounded_batch_exits_zero_only_when_nothing_is_left(self):
        plan = self.dir / "plan.jsonl"
        plan.write_bytes(sd.serialize(approvals(3)))
        ledger = str(self.dir / "cli.sqlite")
        ok = lambda d: None                                      # noqa: E731
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sd, "admin_writer", lambda script: ok), \
                mock.patch.object(sd, "admin_preflight", lambda script=None, **kw: []), \
                mock.patch.object(sd, "live_reconciler", lambda: (lambda d, at: sd.LANDED)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            bounded = sd._main(["apply", "--plan", str(plan), "--ledger", ledger,
                                "--write-pool", "1", "--max-writes", "2"])
            rest = sd._main(["apply", "--plan", str(plan), "--ledger", ledger,
                             "--write-pool", "1"])
        self.assertEqual((bounded, rest), (1, 0))
        first, second = (json.loads(ln) for ln in out.getvalue().splitlines())
        self.assertEqual((first["applied"], first["stop_reason"], second["applied"]),
                         (2, "max_writes", 1))


class RefusePrecedentIsNotFinalTests(unittest.TestCase):
    """A refuse precedent is the same account's earlier refusal of the same claim. It holds
    a request at ``cannot_confirm`` only while nothing on file is newer than that refusal:
    a later document, DSP anchor or proof verdict takes the request out of the rule, and
    the ladder decides it on that evidence."""

    REFUSED = "2026-10-12T05:13:28Z"
    BEFORE = "2026-10-01T00:00:00Z"
    AFTER = "2026-11-02T00:00:00Z"

    def _one(self, request, precedent=None):
        precedent = precedent or {"precedent_key": "k", "outcome": "refuse",
                                  "request_id": rid(9), "decided_at": self.REFUSED}
        return sd.plan(snapshot([request], precedent=[precedent]), now=NOW)[0]

    # ── the ladder ───────────────────────────────────────────────────────────
    def test_evidence_after_the_refusal_takes_the_request_out_of_the_rule(self):
        d = self._one(row(1, precedent_key="k", evidence_at=self.AFTER))
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("ask", "ask", "proof_on_file_undecided"))
        self.assertEqual(d.superseded_precedent, rid(9))

    def test_evidence_before_the_refusal_leaves_it_standing(self):
        d = self._one(row(1, precedent_key="k", evidence_at=self.BEFORE))
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("precedent", "cannot_confirm", "precedent_refuse"))
        self.assertIsNone(d.superseded_precedent)

    def test_evidence_at_the_refusals_own_second_is_not_after_it(self):
        d = self._one(row(1, precedent_key="k", evidence_at=self.REFUSED))
        self.assertEqual((d.rule, d.outcome), ("precedent", "cannot_confirm"))

    def test_no_evidence_leaves_it_standing(self):
        d = self._one(row(1, precedent_key="k"))
        self.assertEqual((d.rule, d.outcome), ("precedent", "cannot_confirm"))
        self.assertIsNone(d.superseded_precedent)

    def test_a_refusal_with_no_measured_time_does_not_stand_over_evidence(self):
        unmeasured = {"precedent_key": "k", "outcome": "refuse", "request_id": rid(9)}
        with_evidence = self._one(row(1, precedent_key="k", evidence_at=self.BEFORE), unmeasured)
        self.assertEqual((with_evidence.rule, with_evidence.superseded_precedent), ("ask", rid(9)))
        without = self._one(row(1, precedent_key="k"), unmeasured)
        self.assertEqual((without.rule, without.outcome), ("precedent", "cannot_confirm"))

    def test_an_unreadable_refusal_time_is_unmeasured(self):
        garbled = {"precedent_key": "k", "outcome": "refuse", "request_id": rid(9),
                   "decided_at": "last tuesday"}
        d = self._one(row(1, precedent_key="k", evidence_at=self.BEFORE), garbled)
        self.assertEqual(d.rule, "ask")

    def test_the_replicas_time_format_orders_against_the_stores(self):
        """The replica casts ``updatedat`` as ``YYYY-MM-DD HH:MM:SS.ffffff UTC``; the
        stores write ``...Z``. Compared as text the space sorts below every ``T``."""
        replica = {"precedent_key": "k", "outcome": "refuse", "request_id": rid(9),
                   "decided_at": "2026-10-12 05:13:28.100333 UTC"}
        earlier = self._one(row(1, precedent_key="k", evidence_at="2026-10-12T05:13:27Z"), replica)
        later = self._one(row(1, precedent_key="k", evidence_at="2026-10-12T05:13:29Z"), replica)
        self.assertEqual((earlier.rule, later.rule), ("precedent", "ask"))

    def test_an_approve_precedent_is_never_set_aside(self):
        approve = {"precedent_key": "k", "outcome": "approve", "request_id": rid(9)}
        d = self._one(row(1, precedent_key="k", evidence_at=self.AFTER), approve)
        self.assertEqual((d.rule, d.outcome), ("precedent", "approve"))
        self.assertIsNone(d.superseded_precedent)

    def test_a_later_approve_verdict_decides_the_request(self):
        d = self._one(row(1, precedent_key="k", proof_verdict="approve", proof_id="a" * 64,
                          proof_received_at=self.AFTER, evidence_at=self.AFTER))
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("proof_verdict", "approve", "proof_verdict_approve"))
        self.assertEqual(d.superseded_precedent, rid(9))

    def test_a_later_refuse_verdict_is_an_ask_not_a_dead_end(self):
        d = self._one(row(1, precedent_key="k", proof_verdict="refuse",
                          proof_received_at=self.AFTER, evidence_at=self.AFTER))
        self.assertEqual((d.rule, d.outcome, d.reason_code),
                         ("proof_verdict", "ask", "proof_verdict_refuse"))

    def test_an_approve_verdict_older_than_the_refusal_does_not_approve(self):
        d = self._one(row(1, precedent_key="k", proof_verdict="approve", proof_id="a" * 64,
                          proof_received_at=self.BEFORE, evidence_at=self.BEFORE))
        self.assertEqual((d.rule, d.outcome), ("precedent", "cannot_confirm"))

    def test_a_snapshot_row_with_only_a_verdict_time_still_has_evidence(self):
        """A snapshot written before ``evidence_at`` existed carries ``proof_received_at``
        only. That time is evidence, so such a row is not read as having none."""
        d = self._one(row(1, precedent_key="k", proof_received_at=self.AFTER))
        self.assertEqual((d.rule, d.superseded_precedent), ("ask", rid(9)))

    def test_an_unreadable_evidence_time_stops_the_snapshot(self):
        with self.assertRaises(sd.DrainError):
            snapshot([row(1, precedent_key="k", evidence_at="soon")])

    def test_a_filed_document_stops_an_asked_request_expiring(self):
        asked = dict(expires_at="2026-10-01T00:00:00Z", asked_at="2026-09-01T00:00:00Z")
        bare = sd.plan(snapshot([row(1, **asked)]), now=NOW)[0]
        filed = sd.plan(snapshot([row(1, evidence_at="2026-09-15T00:00:00Z", **asked)]), now=NOW)[0]
        self.assertEqual((bare.rule, bare.outcome), ("expired", "cannot_confirm"))
        self.assertEqual((filed.rule, filed.outcome, filed.reason_code),
                         ("ask", "ask", "proof_on_file_undecided"))

    def test_a_filed_document_with_no_verdict_is_an_ask_under_the_same_ledger_key(self):
        """A request with a filed document and no verdict says so in its reason. The rule
        and the outcome do not change, so the ledger key does not: a row already applied
        as ``no_rule_matched`` is skipped, not applied a second time."""
        bare = sd.plan(snapshot([row(1)]), now=NOW)[0]
        filed = sd.plan(snapshot([row(1, evidence_at=self.AFTER)]), now=NOW)[0]
        self.assertEqual((bare.rule, bare.outcome, bare.reason_code),
                         ("ask", "ask", "no_rule_matched"))
        self.assertEqual((filed.rule, filed.outcome, filed.reason_code),
                         ("ask", "ask", "proof_on_file_undecided"))
        self.assertEqual(bare.decision_key, filed.decision_key)
        self.assertIsNone(filed.superseded_precedent)

    # ── the plan file and the ledger ─────────────────────────────────────────
    def test_the_plan_row_names_the_refusal_it_set_aside(self):
        d = self._one(row(1, precedent_key="k", evidence_at=self.AFTER))
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "plan.jsonl"
            path.write_bytes(sd.serialize([d]))
            line = json.loads(path.read_text().splitlines()[0])
            self.assertEqual(line["superseded_precedent"], rid(9))
            self.assertEqual(sd.parse_plan(path.read_bytes())[0], d)

    def test_new_evidence_reopens_a_request_already_recorded_as_cannot_confirm(self):
        """The ledger skips a decision it already holds. The reopened request has another
        rule and outcome, so another key: it is applied, not skipped."""
        precedent = [{"precedent_key": "k", "outcome": "refuse", "request_id": rid(9),
                      "decided_at": self.REFUSED}]
        before = sd.plan(snapshot([row(1, precedent_key="k")], precedent=precedent), now=NOW)
        after = sd.plan(snapshot([row(1, precedent_key="k", evidence_at=self.AFTER)],
                                 precedent=precedent), now=NOW)
        calls = []
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            first = sd.apply(before, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            same = sd.apply(before, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            reopened = sd.apply(after, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            again = sd.apply(after, db, shards=1, write_pool=1, writer=calls.append, now=NOW)
            self.assertEqual((first["applied"], same["applied"], same["skipped"]), (1, 0, 1))
            self.assertEqual((reopened["applied"], reopened["skipped"]), (1, 0))
            self.assertEqual((again["applied"], again["skipped"]), (0, 1))
            self.assertEqual(
                db.execute("SELECT rule, outcome, reason_code FROM applied"
                           " ORDER BY rowid").fetchall(),
                [("precedent", "cannot_confirm", "precedent_refuse"),
                 ("ask", "ask", "proof_on_file_undecided")])
        self.assertEqual(calls, [], "neither row is a status write")

    # ── the snapshot builder, from the stores ────────────────────────────────
    USER = "1001"
    ROLES = "{Producer}"

    def _stores(self, td, *, verdicts=(), intake=(), anchors=None):
        proofs = str(Path(td) / "proof.sqlite")
        db = sqlite3.connect(proofs)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO verdicts (proof_id, request_id, verdict, created_at)"
                       " VALUES (?,?,?,?)", list(verdicts))
        db.executemany("INSERT INTO proof_intake VALUES (?,?,?)",
                       [(f"i{n}", json.dumps(ids), at) for n, (ids, at) in enumerate(intake)])
        db.commit()
        db.close()
        dsp = str(Path(td) / "dsp.sqlite")
        if anchors is not None:
            db = sqlite3.connect(dsp)
            db.execute("CREATE TABLE dsp_anchors (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                       " run_id TEXT, at TEXT, request_id TEXT, kind TEXT, outcome TEXT)")
            db.executemany("INSERT INTO dsp_anchors (run_id, at, request_id, kind, outcome)"
                           " VALUES ('run', ?, ?, 'dsp_anchor', ?)", list(anchors))
            db.commit()
            db.close()
        return proofs, dsp

    def _replica(self, numbers, refused_at="2026-10-12 05:13:28.100333 UTC"):
        pending = [(rid(n), self.USER, "p1", "user_verification_needed", "2026-11-01T00:00:00Z",
                    "{}", "{}", f"{n:08x}-1111-4111-8111-111111111111", self.ROLES)
                   for n in numbers]
        decided = [(rid(100 + n), "rejected", self.USER,
                    f"{n:08x}-1111-4111-8111-111111111111", self.ROLES, refused_at)
                   for n in numbers]

        def q(sql):
            return list(decided) if "status IN ('approved', 'rejected')" in sql else list(pending)
        return q

    def _decisions(self, td, numbers, **stores):
        proofs, dsp = self._stores(td, **stores)
        rows = sd.replica_snapshot_rows(self._replica(numbers), proof_store_path=proofs,
                                        dsp_store_path=dsp)
        path = Path(td) / "snap.jsonl"
        path.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
        return {d.request_id: d for d in
                sd.plan(sd._build_snapshot(_args(snapshot=str(path))), now=NOW)}

    def test_each_kind_of_later_evidence_reopens_its_request(self):
        """One request per kind, each with the same account's earlier refusal of the same
        claim, read through the real queries and a snapshot file."""
        with tempfile.TemporaryDirectory() as td:
            by_id = self._decisions(
                td, [1, 2, 3, 4, 5, 6, 7],
                # 1: a document filed after the refusal; 5: one filed before it
                intake=[([rid(1)], self.AFTER), ([rid(5)], self.BEFORE)],
                # 2: an anchor built after the refusal; 6: an anchor that was refused
                anchors=[(self.AFTER, rid(2), "built"), (self.AFTER, rid(6), "refused")],
                # 3: a proof verdict that decides nothing, recorded after the refusal;
                # 7: one that approves the claimed role
                verdicts=[("c" * 64, f"{rid(3)}#Producer", "SUSPECT", self.AFTER),
                          ("d" * 64, f"{rid(7)}#Producer", "GENUINE", self.AFTER)])
        got = {n: (by_id[rid(n)].rule, by_id[rid(n)].outcome, by_id[rid(n)].reason_code,
                   by_id[rid(n)].superseded_precedent) for n in range(1, 8)}
        still = ("precedent", "cannot_confirm", "precedent_refuse", None)
        self.assertEqual(got[1], ("ask", "ask", "proof_on_file_undecided", rid(101)))
        self.assertEqual(got[2], ("ask", "ask", "proof_on_file_undecided", rid(102)))
        self.assertEqual(got[3], ("ask", "ask", "proof_on_file_undecided", rid(103)))
        self.assertEqual(got[7], ("proof_verdict", "approve", "proof_verdict_approve", rid(107)))
        self.assertEqual(by_id[rid(7)].evidence_anchor, "d" * 64)
        self.assertEqual(got[4], still, "nothing on file")
        self.assertEqual(got[5], still, "a document older than the refusal")
        self.assertEqual(got[6], still, "a refused anchor is the record of no anchor")

    def test_a_written_anchor_counts_as_a_built_one_does(self):
        with tempfile.TemporaryDirectory() as td:
            by_id = self._decisions(td, [1], anchors=[(self.AFTER, rid(1), "written")])
        self.assertEqual(by_id[rid(1)].superseded_precedent, rid(101))

    def test_the_newest_refusal_of_a_claim_is_the_one_evidence_must_postdate(self):
        decided = [("d1", "rejected", "u1", "trk-1", "{Producer}", "2026-01-05 00:00:00.000000 UTC"),
                   ("d2", "rejected", "u1", "trk-1", "{Producer}", "2026-10-12 05:13:28.100333 UTC"),
                   ("d3", "rejected", "u1", "trk-1", "{Producer}", "2026-03-01 00:00:00.000000 UTC")]
        _rows, precedent = sd.decided_facts(lambda _sql: decided)
        self.assertEqual([(p["outcome"], p["request_id"], p["decided_at"]) for p in precedent],
                         [("refuse", "d1", "2026-10-12T05:13:28Z")])

    def test_one_unreadable_refusal_time_leaves_the_claims_time_unmeasured(self):
        for bad in (None, "", "not a time"):
            with self.subTest(bad=bad):
                decided = [("d1", "rejected", "u1", "trk-1", "{Producer}", "2026-10-12 05:13:28 UTC"),
                           ("d2", "rejected", "u1", "trk-1", "{Producer}", bad),
                           ("d3", "rejected", "u1", "trk-1", "{Producer}", "2026-11-01 00:00:00 UTC")]
                _rows, precedent = sd.decided_facts(lambda _sql: decided)
                self.assertIsNone(precedent[0]["decided_at"])

    def test_an_approved_claim_carries_no_refusal_time(self):
        decided = [("d1", "rejected", "u1", "trk-1", "{Producer}", "2026-10-12 05:13:28 UTC"),
                   ("d2", "approved", "u1", "trk-1", "{Producer}", "2026-10-13 05:13:28 UTC")]
        _rows, precedent = sd.decided_facts(lambda _sql: decided)
        self.assertEqual(precedent, [{"precedent_key": precedent[0]["precedent_key"],
                                      "outcome": "approve", "request_id": "d2"}])

    #: The replica statements name a Trino table and Trino ``UUID`` literals. sqlite
    #: resolves neither, so exactly those two tokens are adapted for execution: the select
    #: list in the order it is written, the filter and the time cast run as written.
    TRACK = "33333333-3333-4333-8333-333333333333"
    D1 = "11111111-1111-4111-8111-111111111111"
    D2 = "22222222-2222-4222-8222-222222222222"

    @classmethod
    def _runnable(cls, statement):
        return (statement.replace("postgresql_core.public.", "")
                .replace("UUID '", "'"))

    def _decided_replica(self, statement=None):
        """A query function over a sqlite ``credit_requests`` shaped like the replica's,
        holding two rejections of one claim, run against ``statement`` when given."""
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE credit_requests (id TEXT, status TEXT, userid TEXT,"
                   " trackid TEXT, credits TEXT, updatedat TEXT, deletedat TEXT)")
        db.executemany("INSERT INTO credit_requests VALUES (?,?,?,?,?,?,NULL)",
                       [(self.D1, "rejected", "u1", self.TRACK, self.ROLES,
                         "2026-10-12 05:13:28.100333 UTC"),
                        (self.D2, "rejected", "u1", self.TRACK, self.ROLES,
                         "2026-03-01 00:00:00.000000 UTC")])

        def q(sql):
            return [list(r) for r in db.execute(self._runnable(statement or sql))]
        return q

    def test_the_decided_read_maps_each_rows_refusal_time(self):
        """``DECIDED_SQL`` is executed, not read: the time in its sixth select expression
        is the ``decided_at`` the refuse precedent carries."""
        _rows, precedent = sd.decided_facts(self._decided_replica())
        self.assertEqual([(p["outcome"], p["request_id"], p["decided_at"]) for p in precedent],
                         [("refuse", self.D1, "2026-10-12T05:13:28Z")])

    def test_the_bounded_decided_reads_carry_the_same_refusal_time(self):
        for label, pending in (("by track", {"track_id": self.TRACK}),
                               ("by both reads", {"track_id": self.TRACK,
                                                  "duplicate_of": self.D2})):
            with self.subTest(label):
                _rows, precedent = sd.decided_facts(self._decided_replica(), pending=[pending])
                self.assertEqual([(p["outcome"], p["request_id"], p["decided_at"])
                                  for p in precedent],
                                 [("refuse", self.D1, "2026-10-12T05:13:28Z")])

    def test_a_decided_read_without_the_time_in_place_reads_it_unmeasured(self):
        """The mutation the two tests above must catch: with the time replaced by another
        column, the refusal's ``decided_at`` is unmeasured rather than wrong."""
        moved = sd.DECIDED_SQL.replace("CAST(updatedat AS varchar)", "credits")
        _rows, precedent = sd.decided_facts(self._decided_replica(moved))
        self.assertIsNone(precedent[0]["decided_at"])

    def test_a_filing_names_every_request_it_was_filed_against(self):
        with tempfile.TemporaryDirectory() as td:
            proofs, dsp = self._stores(td, intake=[([rid(1), rid(2).upper()], self.BEFORE),
                                                   ([rid(1)], self.AFTER), ([], self.AFTER)])
            self.assertEqual(sd.evidence_times(proofs, dsp),
                             {rid(1): self.AFTER, rid(2): self.BEFORE})

    def test_a_store_that_cannot_be_read_stops_the_snapshot(self):
        with tempfile.TemporaryDirectory() as td:
            proofs, dsp = self._stores(td, anchors=[])
            cases = {"a proof store with no filings table": ("DROP TABLE proof_intake", proofs),
                     "a DSP store with no anchors table": ("DROP TABLE dsp_anchors", dsp)}
            for name, (statement, path) in cases.items():
                with self.subTest(name):
                    db = sqlite3.connect(path)
                    db.execute(statement)
                    db.commit()
                    db.close()
                    with self.assertRaises(sd.DrainError):
                        sd.evidence_times(proofs, dsp)
                    db = sqlite3.connect(path)
                    db.execute(INTAKE_DDL if "intake" in statement else
                               "CREATE TABLE dsp_anchors (at TEXT, request_id TEXT, outcome TEXT)")
                    db.commit()
                    db.close()

    def test_a_filing_with_an_unreadable_time_or_id_list_stops_the_snapshot(self):
        for ids, at in ((json.dumps([rid(1)]), "yesterday"), ('{"a": 1}', self.AFTER),
                        ("not json", self.AFTER)):
            with self.subTest(ids=ids, at=at), tempfile.TemporaryDirectory() as td:
                proofs, dsp = self._stores(td)
                db = sqlite3.connect(proofs)
                db.execute("INSERT INTO proof_intake VALUES ('i', ?, ?)", (ids, at))
                db.commit()
                db.close()
                with self.assertRaises(sd.DrainError):
                    sd.evidence_times(proofs, dsp)

    def test_a_missing_store_is_no_evidence_of_that_kind(self):
        self.assertEqual(sd.evidence_times("/nonexistent/proof.sqlite", NO_DSP_STORE), {})



class _FakeCore:
    """A core that does with a status write what core does: it moves the row, stamps
    ``updatedat``, and sends its notice on every move to ``approved`` or ``rejected``
    (core refuses ``notify: false`` on a move to ``rejected``). The replica reads are
    answered from the same rows, so a write is visible to the next snapshot."""

    WRITE_CLOCK = "2026-11-11 12:00:00.000000 UTC"

    def __init__(self):
        self.rows: dict[str, dict] = {}
        self.writes: list[tuple[str, str, str]] = []
        self.notices: list[tuple[str, str]] = []

    def add(self, n, status, *, user, track, roles="{Producer}", updated=None,
            duplicate_of=None):
        self.rows[rid(n)] = {"status": status, "user": user, "track": track, "roles": roles,
                             "updated": updated, "duplicate_of": duplicate_of}

    def query(self, sql):
        decided = "status IN ('approved', 'rejected')" in sql
        out = []
        for request_id, r in self.rows.items():
            if decided and r["status"] in ("approved", "rejected"):
                out.append((request_id, r["status"], r["user"], r["track"], r["roles"],
                            r["updated"]))
            elif not decided and r["status"] in ("user_verification_needed", "unverified"):
                vd = {"duplicate_of": r["duplicate_of"]} if r["duplicate_of"] else {}
                out.append((request_id, r["user"], "p1", r["status"], "2026-11-01T00:00:00Z",
                            json.dumps(vd), "{}", r["track"], r["roles"]))
        return out

    def run(self, argv, **_kw):
        path, body = argv[-2], json.loads(argv[-1])
        for request_id in body["requestIds"]:
            row = self.rows[request_id]
            row["status"], row["updated"] = body["status"], self.WRITE_CLOCK
            self.writes.append((path, request_id, body["status"]))
            if body["status"] in ("approved", "rejected"):
                self.notices.append((body["status"], request_id))

        class Proc:
            returncode = 0
            stderr = ""
            stdout = json.dumps({"http_status": 200, "body": json.dumps(
                {"data": {"updatedIds": body["requestIds"]}})})
        return Proc()

    def writer(self, td):
        token = Path(td) / "scale-drain.token"
        token.write_text("s3cret\n")
        return sd.admin_writer("/opt/hydra/scripts/muso-admin-api.sh", runner=self.run,
                               token_file=str(token))


class DuplicateIsNeverARefusalTests(unittest.TestCase):
    """A request that names a decided request as its duplicate is never closed.

    The close was a core ``rejected``. core tells the customer "rejected" on that move,
    and the next snapshot read the closed row as this claimant's refusal of the claim,
    dated the day of the close: a refuse precedent newer than everything the customer had
    filed. So the drain makes no such write. These cases run plan -> apply -> plan again
    against a core that applies what it is sent and notifies as core does, through the
    real replica reads, the real writer and a real ledger."""

    USER, OTHER = "1001", "2002"
    T1 = "00000001-1111-4111-8111-111111111111"
    T2 = "00000002-1111-4111-8111-111111111111"
    T3 = "00000003-1111-4111-8111-111111111111"
    REFUSED = "2026-10-12 05:13:28.100333 UTC"
    AFTER = "2026-11-02T00:00:00Z"

    def _proofs(self, td, intake=()):
        proofs = str(Path(td) / "proof.sqlite")
        db = sqlite3.connect(proofs)
        db.execute("CREATE TABLE verdicts (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                   " proof_id TEXT, request_id TEXT, verdict TEXT, created_at TEXT)")
        db.execute(INTAKE_DDL)
        db.executemany("INSERT INTO proof_intake VALUES (?,?,?)",
                       [(f"i{n}", json.dumps(ids), at) for n, (ids, at) in enumerate(intake)])
        db.commit()
        db.close()
        return proofs

    def _plan(self, td, core, proofs, name):
        rows = sd.replica_snapshot_rows(core.query, proof_store_path=proofs,
                                        dsp_store_path=NO_DSP_STORE)
        path = Path(td) / f"{name}.jsonl"
        path.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
        plan = sd.plan(sd._build_snapshot(_args(snapshot=str(path))), now=NOW)
        return plan, {d.request_id: (d.rule, d.outcome, d.reason_code) for d in plan}

    def test_naming_ones_own_refused_request_leaves_the_claim_reopenable(self):
        core = _FakeCore()
        core.add(100, "rejected", user=self.USER, track=self.T1, updated=self.REFUSED)
        # 1 names the refused request as its duplicate; 2 is the same claim again and
        # names nothing. Both have a document filed after the refusal.
        core.add(1, "user_verification_needed", user=self.USER, track=self.T1,
                 duplicate_of=rid(100))
        core.add(2, "user_verification_needed", user=self.USER, track=self.T1)
        ask = ("ask", "ask", "proof_on_file_undecided")
        with tempfile.TemporaryDirectory() as td:
            proofs = self._proofs(td, [([rid(1)], self.AFTER), ([rid(2)], self.AFTER)])
            plan, first = self._plan(td, core, proofs, "first")
            self.assertEqual(first, {rid(1): ask, rid(2): ask})
            by_id = {d.request_id: d for d in plan}
            self.assertEqual(by_id[rid(1)].superseded_precedent, rid(100))
            self.assertIsNone(by_id[rid(1)].duplicate_of)
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            stats = sd.apply(plan, db, shards=1, write_pool=1, writer=core.writer(td), now=NOW)
            self.assertEqual(stats["applied"], 2)
            self.assertEqual(core.writes, [], "no status is written for either request")
            self.assertEqual(core.notices, [], "and the customer is told nothing by core")
            self.assertEqual(core.rows[rid(1)]["status"], "user_verification_needed")
            self.assertEqual(core.rows[rid(100)]["updated"], self.REFUSED)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 0)
            _, second = self._plan(td, core, proofs, "second")
        self.assertEqual(second, first, "the refusal is no newer after the run than before it")

    def test_naming_ones_own_approved_request_is_approved_and_never_rejected(self):
        core = _FakeCore()
        core.add(200, "approved", user=self.USER, track=self.T2,
                 updated="2026-09-01 00:00:00.000000 UTC")
        core.add(3, "user_verification_needed", user=self.USER, track=self.T2,
                 duplicate_of=rid(200))
        with tempfile.TemporaryDirectory() as td:
            plan, got = self._plan(td, core, self._proofs(td), "first")
            self.assertEqual(got, {rid(3): ("precedent", "approve", "precedent_match")})
            self.assertEqual(plan[0].evidence_anchor, rid(200))
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            sd.apply(plan, db, shards=1, write_pool=1, writer=core.writer(td), now=NOW)
        self.assertEqual(core.writes, [("/admin/credit-requests", rid(3), "approved")])
        self.assertEqual(core.notices, [("approved", rid(3))])
        self.assertEqual(core.rows[rid(3)]["status"], "approved")

    def test_naming_a_request_that_decides_nothing_about_this_claim_writes_nothing(self):
        core = _FakeCore()
        # 300 is another account's refusal on the same track; 400 is still pending.
        core.add(300, "rejected", user=self.OTHER, track=self.T3, updated=self.REFUSED)
        core.add(400, "unverified", user=self.OTHER, track=self.T3)
        core.add(4, "user_verification_needed", user=self.USER, track=self.T3,
                 duplicate_of=rid(300))
        core.add(5, "user_verification_needed", user=self.USER, track=self.T3,
                 duplicate_of=rid(400))
        with tempfile.TemporaryDirectory() as td:
            plan, got = self._plan(td, core, self._proofs(td), "first")
            self.assertEqual(got[rid(4)], ("ask", "ask", "no_rule_matched"),
                             "another account's refusal is no precedent for this claimant")
            self.assertEqual(got[rid(5)], ("duplicate", "unmatched", "unmatched_duplicate"),
                             "an undecided original sets the row aside, unwritten")
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            sd.apply(plan, db, shards=1, write_pool=1, writer=core.writer(td), now=NOW)
        self.assertEqual((core.writes, core.notices), ([], []))

    def test_no_request_is_planned_as_a_close_whatever_its_original_decided(self):
        for decided in ("approved", "rejected"):
            for same_claimant in (True, False):
                with self.subTest(decided=decided, same_claimant=same_claimant):
                    core = _FakeCore()
                    core.add(100, decided, updated=self.REFUSED, track=self.T1,
                             user=self.USER if same_claimant else self.OTHER)
                    core.add(1, "unverified", user=self.USER, track=self.T1,
                             duplicate_of=rid(100))
                    with tempfile.TemporaryDirectory() as td:
                        plan, _ = self._plan(td, core, self._proofs(td), "p")
                    self.assertNotIn(plan[0].outcome, sd.RETIRED_OUTCOMES)
                    self.assertNotIn(plan[0].outcome, ("reject", "close_duplicate"))
                    self.assertNotEqual(sd.WRITE_STATUS.get(plan[0].outcome), "rejected")

    def test_a_plan_file_made_before_this_change_is_refused_whole(self):
        """An older plan may still carry a close. Applying it would write ``rejected``."""
        keep = sd.plan(snapshot([row(2)]), now=NOW)[0]
        old = dict(keep.as_row(), request_id=rid(1), rule="duplicate", outcome="close_duplicate",
                   reason_code="duplicate_of_decided", duplicate_of=rid(9), status="unverified",
                   decision_key=sd.decision_key(rid(1), "duplicate", "close_duplicate"))
        text = "".join(json.dumps(r, sort_keys=True) + "\n" for r in (keep.as_row(), old))
        core = _FakeCore()
        core.add(1, "unverified", user=self.USER, track=self.T1)
        with tempfile.TemporaryDirectory() as td:
            db = sd.open_ledger(str(Path(td) / "l.sqlite"))
            with self.assertRaises(sd.DrainError) as ctx:
                sd.apply(sd.parse_plan(text), db, shards=1, write_pool=1,
                         writer=core.writer(td), now=NOW)
            self.assertIn("'close_duplicate'", str(ctx.exception))
            self.assertIn("plan again", str(ctx.exception))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0,
                             "the row beside it is not recorded either")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM intents").fetchone()[0], 0)
        self.assertEqual((core.writes, core.notices), ([], []))

    def test_the_cli_refuses_that_plan_and_exits_non_zero(self):
        keep = sd.plan(snapshot([row(2)]), now=NOW)[0]
        old = dict(keep.as_row(), request_id=rid(1), rule="duplicate", outcome="close_duplicate",
                   reason_code="duplicate_of_decided", duplicate_of=rid(9), status="unverified",
                   decision_key=sd.decision_key(rid(1), "duplicate", "close_duplicate"))
        with tempfile.TemporaryDirectory() as td:
            plan = Path(td) / "plan.jsonl"
            plan.write_text(json.dumps(old, sort_keys=True) + "\n")
            ledger = Path(td) / "l.sqlite"
            proc = subprocess.run(cli("apply", "--plan", str(plan), "--ledger", str(ledger),
                                      "--no-write"), cwd=SCRIPTS, capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("close_duplicate", proc.stdout + proc.stderr)
            db = sqlite3.connect(str(ledger))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM applied").fetchone()[0], 0)
            db.close()


if __name__ == "__main__":
    unittest.main()
