"""C5 `validator_reject` (firstmate 174): close only on a current reject_* rule with no claim on the profile, every
rail held, coded-close rows in the ledger, and the executor admits an apply row (shadow never)."""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate  # noqa: E402
from credit_review import validator_reject_close as vr  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "credit_review._fx_real_for_vr", Path(__file__).resolve().parents[1] / "credit_review" / "fable_executor.py")
fx = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fx
_spec.loader.exec_module(fx)

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 10, 31, 1, 30, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow")
LABEL = {"reject_publisher_label_credit": 100.0, "reject_artist_credit": 0.0}


def facts(status="unverified", uid=42, pop=30, rules=None, owns=False, source="industry", deleted=False):
    return fx.Facts(status=status, user_id=uid, popularity=pop, deleted=deleted,
                    rules=LABEL if rules is None else rules, metadata_source=source, paid=True, owns_profile=owns)


def run(f=None, v9="no_anchor", gate=ALLOW, held=(), paid=frozenset({42})):
    fm = {R1: f if f is not None else facts()}
    return vr.evaluate([R1], fm, {R1: v9} if v9 else {}, lambda u: gate, lambda u: list(held), paid)


class EvaluateTest(unittest.TestCase):
    def one(self, **kw):
        rows, _ = run(**kw)
        self.assertEqual(len(rows), 1)
        return rows[0]

    def test_a_current_reject_with_no_claim_closes_with_its_rule(self):
        r = self.one()
        self.assertEqual((r.decision, r.reason_code, r.expected_status, r.paid),
                         ("close", "reject_publisher_label_credit", "unverified", True))

    def test_every_hold(self):
        cases = [
            ({"f": facts(rules={"reject_artist_credit": 0.0})}, "no_current_reject_rule"),
            ({"f": facts(rules={"reject_high_velocity_profile": 100.0})}, "no_current_reject_rule"),   # retired
            ({"f": facts(rules={**LABEL, "review_big_track": 100.0})}, "review_hold"),
            ({"f": facts(rules={**LABEL, "review_y": 40.0})}, "review_hold"),        # the server holds from 30 (QA)
            ({"f": facts(rules={**LABEL, "review_y": 30.0})}, "review_hold"),
            ({"f": facts(owns=True)}, "submitter_has_claim_on_profile"),          # batch0: never reject an owner
            ({"f": facts(owns=None)}, "profile_claim_unknown"),
            ({"f": facts(pop=0)}, "big_or_unknown_popularity"),
            ({"f": facts(pop=60)}, "big_or_unknown_popularity"),
            ({"f": facts(source="client")}, "big_or_unknown_popularity"),
            ({"gate": account_gate.GateResult("hold", ("x",))}, "account_gate_hold"),
            ({"gate": account_gate.GateResult("allow", ("on the watchlist",))}, "watchlisted_account"),
            ({"held": ["R8_account_hold"]}, "R8_account_hold"),
            ({"v9": "anchor"}, "dsp_anchor"),
            ({"v9": "unknown"}, "v9_unread"),
            ({"v9": None}, "v9_unread"),
        ]
        for kw, want in cases:
            r = self.one(**kw)
            self.assertEqual((r.decision, r.reason_code), ("hold", want), kw)

    def test_a_review_score_below_the_hold_threshold_does_not_hold(self):
        self.assertEqual(self.one(f=facts(rules={**LABEL, "review_y": 29.0})).decision, "close")

    def test_the_threshold_mirrors_the_server_policy(self):
        from credit_review import policy
        self.assertEqual(vr.REVIEW_HOLD_MIN, policy.HOLD_RULE_MIN_SCORE)

    def test_unreadable_gate_or_holds_never_close(self):
        def boom(u):
            raise RuntimeError("down")
        for g, h in ((boom, lambda u: []), (lambda u: ALLOW, boom)):
            rows, _ = vr.evaluate([R1], {R1: facts()}, {R1: "no_anchor"}, g, h, None)
            self.assertEqual(rows[0].decision, "hold")

    def test_closed_or_missing_rows_get_no_row(self):
        rows, skipped = vr.evaluate([R1, R2], {R1: facts(status="rejected")}, {}, lambda u: ALLOW, lambda u: [],
                                    None)
        self.assertEqual((rows, skipped), ([], {"not_open:rejected": 1, "not_open:missing": 1}))


class RecordTest(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.path = f"{d}/ledger.sqlite3"
        self.db = sqlite3.connect(self.path)

    def test_shadow_rows_carry_the_coded_shape_and_never_duplicate(self):
        rows, _ = run()
        hold, _ = run(f=facts(owns=True))
        rec = vr.record(self.db, "r1", "shadow", rows + hold, NOW)
        self.assertEqual((rec["close"], rec["hold"]), (1, {"submitter_has_claim_on_profile": 1}))
        got = self.db.execute("SELECT decision, mode, evidence_kind, reason_code, rule_version, expected_status "
                              "FROM decisions ORDER BY id").fetchall()
        self.assertEqual(got[0][:4], ("close", "shadow", "validator_reject", "reject_publisher_label_credit"))
        self.assertTrue(got[0][4].startswith(vr.RULE_ID + "+"))
        self.assertEqual(self.db.execute("SELECT action, outcome FROM decision_outcomes").fetchall(),
                         [("close", "shadow")])
        self.assertEqual(vr.record(self.db, "r2", "shadow", rows, NOW)["duplicate"], 1)

    def test_the_executor_admits_an_apply_row_and_never_a_shadow_one(self):
        rows, _ = run()
        d = tempfile.mkdtemp()
        for mode, want in (("apply", None), ("shadow", "coded_outcome_not_apply:shadow")):
            db = sqlite3.connect(self.path)
            rec = vr.record(db, f"r-{mode}", mode, rows, NOW)
            doc = vr.tray_docs(rec["close_ids"])["unverified"]
            Path(f"{d}/t-{mode}.json").write_text(json.dumps(doc))
            tray = fx.load_tray(f"{d}/t-{mode}.json")
            self.assertEqual((tray.action, tray.refuse_if_dsp_anchor, tray.rows[0].rule),
                             ("reject", True, "reject_publisher_label_credit"))
            oc = fx.ledger_outcomes([tray.rows[0].coded_outcome], path=self.path)
            self.assertEqual(fx.coded_outcome_refusal(tray, tray.rows[0], oc), want, mode)


class WriteTimeRecheckTest(unittest.TestCase):
    """QA #1559: the executor re-checks every C5 rail right before the PUT (tray recheck_evidence validator_reject)."""

    def row(self, rule="reject_publisher_label_credit"):
        return fx.TrayRow(R1, 42, "decisions-1", rule, True)

    def test_a_dropped_rule_a_new_review_hold_or_r8_refuses(self):
        ok = vr.recheck_rows([self.row()], lambda ids: {R1: facts()}, lambda u: [])
        self.assertEqual(ok, {R1: ""})
        cases = [
            ((lambda ids: {R1: facts(rules={"reject_publisher_label_credit": 1.0})}, lambda u: []), "rule_no_longer"),
            ((lambda ids: {R1: facts(rules={**LABEL, "review_x": 100.0})}, lambda u: []), "review_hold"),
            ((lambda ids: {R1: facts(rules={**LABEL, "review_x": 40.0})}, lambda u: []), "review_hold"),
            ((lambda ids: {R1: facts()}, lambda u: ["R8_account_hold"]), "R8_account_hold"),
            ((lambda ids: {}, lambda u: []), "unknown:row_not_found"),
        ]
        for (ff, hf), want in cases:
            self.assertTrue(vr.recheck_rows([self.row()], ff, hf)[R1].startswith(want), want)
        self.assertTrue(vr.recheck_rows([self.row("reject_high_velocity_profile")],
                                        lambda ids: {R1: facts(rules={"reject_high_velocity_profile": 100.0})},
                                        lambda u: [])[R1].startswith("rule_no_longer"))

    def test_the_executor_dispatches_validator_reject_trays_to_this_recheck(self):
        real = vr.recheck_rows
        vr.recheck_rows = lambda rows: {R1: "review_hold:review_x"}
        try:
            self.assertEqual(fx.coded_evidence([self.row()], "validator_reject"), {R1: "review_hold:review_x"})
        finally:
            vr.recheck_rows = real

    def test_trays_ask_for_the_v9_and_the_c5_recheck(self):
        rows, _ = run()
        d = tempfile.mkdtemp()
        db = sqlite3.connect(f"{d}/l.sqlite3")
        rec = vr.record(db, "r1", "apply", rows, NOW)
        doc = vr.tray_docs(rec["close_ids"])["unverified"]
        self.assertEqual((doc["refuse_if_dsp_anchor"], doc["recheck_evidence"]), (True, "validator_reject"))


class PublishTest(unittest.TestCase):
    def test_publication_is_exactly_once_and_recovers_a_crash(self):
        d = tempfile.mkdtemp()
        db = sqlite3.connect(f"{d}/l.sqlite3")
        rows, _ = run()
        vr.record(db, "r1", "apply", rows, NOW)                       # crash here: committed, no tray
        out = f"{d}/trays"
        paths = vr.publish(db, "r2", out, NOW)
        self.assertEqual(len(paths), 1)
        self.assertEqual(vr.publish(db, "r3", out, NOW), [])          # never twice
        # a crash after the marks but before the rename is reconciled under the SAME name
        vr.record(db, "r4", "apply", [vr.Row(R2, 42, "close", "reject_publisher_label_credit", "x", "unverified", 30,
                                             True, "allow", "no_anchor")], NOW)
        real = vr.os.replace
        vr.os.replace = lambda a, b: (_ for _ in ()).throw(OSError("killed"))
        try:
            with self.assertRaises(OSError):
                vr.publish(db, "r5", out, NOW)
        finally:
            vr.os.replace = real
        self.assertEqual(vr.publish(db, "r6", out, NOW), [])
        self.assertEqual(len([p for p in Path(out).iterdir() if p.suffix == ".json"]), 2)
        self.assertFalse(list(Path(out).glob("*.tmp")))

    def test_two_concurrent_publishers_never_put_one_decision_in_two_trays(self):
        """QA #1559: publisher B runs while A holds the write lock between its selection and its marks."""
        d = tempfile.mkdtemp()
        path = f"{d}/l.sqlite3"
        db = sqlite3.connect(path)
        rows, _ = run()
        vr.record(db, "r1", "apply", rows, NOW)
        out = f"{d}/trays"
        db_b = sqlite3.connect(path, timeout=0.2)
        real = vr.unpublished
        seen = []

        def racing(conn):
            got = real(conn)
            if not seen:
                seen.append(True)
                try:
                    seen.append(vr.publish(db_b, "rb", out, NOW))
                except sqlite3.OperationalError as exc:
                    seen.append(f"blocked:{exc}")
            return got
        vr.unpublished = racing
        try:
            paths = vr.publish(db, "ra", out, NOW)
        finally:
            vr.unpublished = real
        self.assertTrue(str(seen[1]).startswith("blocked:"), seen)        # B cannot read-then-mark in between
        self.assertEqual(len(paths), 1)
        self.assertEqual(vr.publish(db_b, "rb2", out, NOW), [])            # after A, B finds nothing to publish
        self.assertEqual(len(list(Path(out).glob("*.json"))), 1)

    def test_apply_needs_a_known_paying_list(self):
        self.assertIsNone(vr.paid_refusal(frozenset({1}), None))
        self.assertIn("unknown", vr.paid_refusal(None, "stale"))


class ApplyGateTest(unittest.TestCase):
    def test_apply_is_refused_until_r5_goes_on_the_shadow(self):
        ok = {"apply_enabled": True, "approved_by": "r5", "approval_ref": "x"}
        self.assertIsNone(vr.apply_refusal(ok, kill_files=()))
        for bad in ({**ok, "apply_enabled": False}, {**ok, "approval_ref": None}, {}):
            self.assertIsNotNone(vr.apply_refusal(bad, kill_files=()))
        self.assertIn("apply_enabled", vr.apply_refusal(vr.policy(), kill_files=()))


if __name__ == "__main__":
    unittest.main()
