"""C3 junk_proof + C8 fraud_document (credit_review/doc_close.py): coded document closes, shadow rows in the
coded-close shape, every rail held, the 24 h unbroken fraud standing, and coverage before any fraud close."""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate  # noqa: E402
from credit_review import doc_close as dc  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "credit_review._fx_real_for_dc", Path(__file__).resolve().parents[1] / "credit_review" / "fable_executor.py")
fx = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fx
_spec.loader.exec_module(fx)

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 10, 31, 9, 0, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow")
TAMPER = {"id": "h3_copy_move_region@p1", "family": "file_tamper", "fields": ["track"]}
REUSE = {"id": "h3_byte_reuse", "family": "reuse"}


def facts(status="unverified", uid=42, pop=30, source="industry", deleted=False):
    return fx.Facts(status=status, user_id=uid, popularity=pop, deleted=deleted, rules={}, metadata_source=source,
                    paid=True, owns_profile=False)


class JunkTest(unittest.TestCase):
    def run_junk(self, tied=True, read=True, f=None, v9="no_anchor", gate=ALLOW, held=(), gate_raises=False):
        p = {"request_id": R1, "user_id": 42, "documents": ["i1"], "kinds": ["muso_ui_screenshot"],
             "link": "the document names this track" if tied else None, "sys_001_only": True}
        jl = {"decline_requests": [p] if tied else [], "held_untied": [] if tied else [p]}

        def g(u):
            if gate_raises:
                raise RuntimeError("gate down")
            return gate
        return dc.evaluate_junk(jl, [{"intake_id": "i1", "read": read}], {R1: f or facts()}, {R1: v9}, g,
                                lambda u: list(held), frozenset({42}))

    def test_a_tied_all_junk_read_request_closes(self):
        rows, _ = self.run_junk()
        self.assertEqual([(r.decision, r.reason_code, r.intake_ids, r.paid) for r in rows],
                         [("close", "junk_proof", ["i1"], True)])

    def test_every_hold(self):
        cases = [({"tied": False}, "not_tied"), ({"read": False}, "document_not_read"),
                 ({"f": facts(pop=0)}, "big_or_unknown_popularity"), ({"f": facts(pop=60)}, "big_or_unknown_popularity"),
                 ({"f": facts(source="client")}, "big_or_unknown_popularity"),
                 ({"gate": account_gate.GateResult("hold", ("x",))}, "account_gate_hold"),
                 ({"gate": account_gate.GateResult("allow", ("on the watchlist",))}, "watchlisted_account"),
                 ({"gate_raises": True}, "account_gate_unknown"),
                 ({"held": ["R8"]}, "R8_account_hold"), ({"v9": "anchor"}, "dsp_anchor"),
                 ({"v9": "unknown"}, "v9_unread"),
                 ({"gate": account_gate.GateResult("unknown", ("timeout",))}, "account_gate_unknown")]
        for kw, code in cases:
            rows, _ = self.run_junk(**kw)
            self.assertEqual((rows[0].decision, rows[0].reason_code), ("hold", code), kw)

    def test_a_request_no_longer_open_is_skipped_not_decided(self):
        for f, k in ((facts(status="approved"), "not_open:approved"), (facts(deleted=True), "not_open:deleted")):
            rows, skipped = self.run_junk(f=f)
            self.assertEqual((rows, skipped), ([], {k: 1}))


class FraudTest(unittest.TestCase):
    def deny(self, pair=(TAMPER, REUSE), covers=True, ruling=None, proof="p" * 64, rid_ruling="aaaa"):
        return {"ruling_id": rid_ruling, "proof_id": proof, "intake_id": "i9", "user_id": 42,
                "fraud_signals": [TAMPER, REUSE], "fraud_pair": list(pair), "claim_fields": ["track"],
                "requests": [{"request_id": R1, "role": "Mixing", "outcome_id": 7, "covers": covers}],
                "ruling": ruling}

    def run_fraud(self, deny=None, since=NOW - timedelta(hours=25), f=None, v9="no_anchor", gate=ALLOW, held=(),
                  gate_raises=False):
        def g(u):
            if gate_raises:
                raise RuntimeError("gate down")
            return gate
        iso = since.strftime("%Y-%m-%dT%H:%M:%SZ") if since else None
        return dc.evaluate_fraud(deny if deny is not None else [self.deny()], lambda oid: iso, {R1: f or facts()},
                                 {R1: v9}, g, lambda u: list(held), frozenset({42}), NOW)

    def test_a_positive_covered_document_standing_24h_closes(self):
        rows, _ = self.run_fraud()
        r = rows[0]
        self.assertEqual((r.decision, r.reason_code, r.intake_ids), ("close", "fraud_document", ["i9"]))
        self.assertEqual(r.evidence["signal_ids"], ["h3_copy_move_region@p1", "h3_byte_reuse"])

    def test_every_hold(self):
        same = {"id": "h3_other_tamper", "family": "file_tamper", "fields": ["track"]}
        cases = [({"since": NOW - timedelta(hours=23)}, "within_24h_hold"), ({"since": None}, "forged_since_unknown"),
                 ({"deny": [self.deny(pair=(TAMPER, same))]}, "pair_no_longer_positive"),
                 ({"deny": [self.deny(pair=(TAMPER,))]}, "pair_no_longer_positive"),
                 ({"deny": [self.deny(covers=False)]}, "not_covered"),
                 ({"deny": [self.deny(ruling="not")]}, "ruled_not_forged"),
                 ({"deny": [self.deny(), self.deny(proof="q" * 64)]}, "proof_id_ambiguous"),
                 ({"gate_raises": True}, "account_gate_unknown"), ({"held": ["R8"]}, "R8_account_hold"),
                 ({"gate": account_gate.GateResult("unknown", ("timeout",))}, "account_gate_unknown"),   # QA #1571
                 ({"v9": "anchor"}, "dsp_anchor"), ({"v9": "unknown"}, "v9_unread"),
                 ({"f": facts(pop=75)}, "big_or_unknown_popularity")]
        for kw, code in cases:
            rows, _ = self.run_fraud(**kw)
            self.assertEqual((rows[0].decision, rows[0].reason_code), ("hold", code), kw)

    def test_a_watched_or_gate_held_account_does_not_hold_a_fraud_close(self):
        for gate in (account_gate.GateResult("allow", ("on the watchlist",)), account_gate.GateResult("hold", ("x",))):
            rows, _ = self.run_fraud(gate=gate)
            self.assertEqual(rows[0].decision, "close", gate)

    def test_a_pair_signal_missing_from_the_documents_signals_never_closes(self):
        d = self.deny()
        d["fraud_signals"] = [TAMPER]
        rows, _ = self.run_fraud(deny=[d])
        self.assertEqual(rows[0].reason_code, "pair_no_longer_positive")


class FraudRowsEntrypointTest(unittest.TestCase):
    """QA #1571: the 'not' ruling must reach C8 through the REAL entrypoint (fraud_rows -> tray.forged_tray), and the
    CLI refuses the fraud rule without a rulings file."""

    def setUp(self):
        from credit_verify.docverify.store import VERSION, DocVerifyStore
        self.td = tempfile.TemporaryDirectory()
        self.dv = str(Path(self.td.name) / "dv.sqlite")
        s = DocVerifyStore(self.dv)
        self.proof = "ab12cd34" + "0" * 56
        detail = {"fraud_signals": [TAMPER, REUSE], "fraud_pair": [TAMPER, REUSE], "claim_fields": ["track"],
                  "covers": True}
        s.db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, user_id, source_ref, outcome, "
                     "reason, account_hold, detail_json, version, intake_id) VALUES ('r', '2026-10-30T06:00:00Z', ?, ?, "
                     "'Mixing', 42, 'intercom:1', 'forged_positive', 'pair', 0, ?, ?, 'i9')",
                     (self.proof, R1, json.dumps(detail), VERSION))
        s.db.commit()
        s.db.close()
        self.pdb = sqlite3.connect(":memory:")
        self.pdb.execute("CREATE TABLE proof_intake (intake_id TEXT, subject TEXT, received_at TEXT)")
        spec = importlib.util.spec_from_file_location("credit_doc_close_cli",
                                                      Path(__file__).resolve().parents[1] / "credit-doc-close.py")
        self.cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.cli)

    def tearDown(self):
        self.td.cleanup()

    def rows(self, rulings_text):
        rows, _ = self.cli.fraud_rows(self.dv, self.pdb, frozenset({42}), NOW, rulings_text,
                                      facts_fn=lambda ids: {R1: facts()}, anchors_fn=lambda ids: {R1: "no_anchor"},
                                      gate_fn=lambda u: ALLOW, hold_fn=lambda u: [])
        return [(r.request_id, r.decision, r.reason_code) for r in rows]

    def test_a_document_ruled_not_holds_through_the_entrypoint(self):
        self.assertEqual(self.rows(""), [(R1, "close", "fraud_document")])            # 27 h unbroken: a close
        self.assertEqual(self.rows("ruling: forged-ab12cd34 not"), [(R1, "hold", "ruled_not_forged")])

    def test_the_fraud_rule_refuses_without_a_readable_rulings_file(self):
        import contextlib
        import io
        for argv in (["--rule", "fraud", "--preview"],
                     ["--rule", "fraud", "--preview", "--rulings", str(Path(self.td.name) / "missing.txt")]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(self.cli.main(argv), 2, argv)
            self.assertIn("needs a readable --rulings file", out.getvalue())


class ForgedSinceTest(unittest.TestCase):
    def test_the_24h_clock_restarts_after_any_other_outcome(self):
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY, at TEXT, version TEXT, intake_id TEXT, "
                   "proof_id TEXT, request_id TEXT, role TEXT, outcome TEXT)")
        seq = [("2026-10-28T00:00:00Z", "forged_positive"), ("2026-10-29T00:00:00Z", "unknown"),
               ("2026-10-30T01:00:00Z", "forged_positive"), ("2026-10-30T08:00:00Z", "forged_positive")]
        for at, o in seq:
            db.execute("INSERT INTO dv_outcomes (at, version, intake_id, proof_id, request_id, role, outcome) "
                       "VALUES (?, 'dv-4', 'i9', 'p', ?, 'Mixing', ?)", (at, R1, o))
        db.execute("INSERT INTO dv_outcomes (at, version, intake_id, proof_id, request_id, role, outcome) VALUES "
                   "('2026-10-27T00:00:00Z', 'dv-4', 'i9', 'p', ?, 'Piano', 'forged_positive')", (R1,))
        self.assertEqual(dc.forged_since(db, "dv-4", 4), "2026-10-30T01:00:00Z")
        self.assertEqual(dc.forged_since(db, "dv-4", 1), "2026-10-28T00:00:00Z")
        self.assertIsNone(dc.forged_since(db, "dv-4", 99))
        self.assertIsNone(dc.forged_since(db, "dv-3", 4))                    # another version's history never counts


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.db = sqlite3.connect(str(Path(self.td.name) / "ledger.sqlite3"))

    def tearDown(self):
        self.db.close()
        self.td.cleanup()

    def test_shadow_rows_in_the_coded_close_shape_once_and_never_apply(self):
        rows, _ = JunkTest().run_junk()
        hold, _ = JunkTest().run_junk(tied=False)
        out = dc.record(self.db, "run-1", dc.JUNK, rows + hold, NOW)
        self.assertEqual((out["close"], out["hold"]), (1, {"not_tied": 1}))
        r = self.db.execute("SELECT decision, mode, reason_code, rule_version, intake_ids, gate_state, v9_anchor, "
                            "evidence_kind, decided_at FROM decisions WHERE decision='close'").fetchone()
        self.assertEqual(r[:3], ("close", "shadow", "junk_proof"))
        self.assertTrue(r[3].startswith("C3:junk_proof/v1+"))
        self.assertEqual((json.loads(r[4]), r[5], r[6], r[7], r[8]),
                         (["i1"], "allow", "no_anchor", "junk_proof", "2026-10-31T09:00:00Z"))
        self.assertEqual(self.db.execute("SELECT action, outcome FROM decision_outcomes").fetchall(),
                         [("close", "shadow")])
        self.assertEqual(dc.record(self.db, "run-2", dc.JUNK, rows, NOW)["duplicate"], 1)   # never decided twice
        with self.assertRaises(ValueError):
            dc.record(self.db, "run-3", dc.JUNK, rows, NOW, mode="apply")
        self.assertNotEqual(dc.rule_version(dc.JUNK), dc.rule_version(dc.FRAUD))


if __name__ == "__main__":
    unittest.main()
