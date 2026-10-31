"""Stale-velocity re-validate (Fable [key=held-velocity-revalidate]): every outcome, the green-user guard, fail-closed
reads, the summary shape and the append-only audit rows."""
from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402
from credit_review import stale_velocity as sv  # noqa: E402

R1 = "11111111-1111-4111-8111-111111111111"
# the shape of a live velocity-held verdict: every hold rule scored 0, velocity 100, no positive score rules
VEL = {"reject_high_velocity_profile": 100.0, **{k: 0.0 for k in sv.REQUIRED_HOLD_RULES}}
ALLOW = account_gate.GateResult("allow")


def facts(status="user_verification_needed", uid=42, pop=30, rules=None, owns=False, deleted=False, source=""):
    return fx.Facts(status=status, user_id=uid, popularity=pop, deleted=deleted,
                    rules=VEL if rules is None else rules, metadata_source=source, paid=None, owns_profile=owns)


def run(f=None, v9="APPROVE", gate=ALLOW, held=(), paid=frozenset({42}), cls="person_not_linked"):
    f = {R1: facts()} if f is None else {R1: f}
    return sv.evaluate([(R1, 42)], f, {R1: v9} if v9 is not None else {}, lambda u: gate, lambda u: list(held), paid,
                       {R1: cls})


class OutcomeTest(unittest.TestCase):
    def one(self, **kw):
        rows, _ = run(**kw)
        self.assertEqual(len(rows), 1)
        return rows[0]

    def test_v9_approve_on_a_row_still_carrying_the_retired_rule_is_blocked_not_released(self):
        o = self.one()
        self.assertEqual((o.outcome, sv.DECISION_FOR[o.outcome]), ("blocked_stale_rule", "hold"))
        self.assertEqual(o.evidence["retired_firing"], ["reject_high_velocity_profile"])

    def test_v9_approve_with_no_firing_rule_is_release_anchored(self):
        o = self.one(f=facts(rules={**VEL, "reject_high_velocity_profile": 0.0}))
        self.assertEqual((o.outcome, sv.DECISION_FOR[o.outcome]), ("release_anchored", "approve"))

    def test_owes_proof_is_the_standard_ask(self):
        for cls in sv.OWES_PROOF_CLASSES:
            o = self.one(v9="WAIT", cls=cls)
            self.assertEqual((o.outcome, sv.DECISION_FOR[o.outcome]), ("ask", "defer"), cls)

    def test_contradictions_duplicates_and_unread_classes_hold_not_ask(self):
        # doc-verify 154: the paid user's dsp_conflict rows are a hold signal, not an ask
        for v9, cls in (("WAIT", "dsp_conflict"), ("WAIT", "others_only"), ("WAIT", "capture_pending"),
                        ("WAIT", "unknown"), ("WAIT", "org_role_on_person_profile"), ("WAIT", ""),
                        ("WAIT", "anchored_but_blocked"), ("DUPLICATE", "duplicate"), ("DECLINE", "decline")):
            o = self.one(v9=v9, cls=cls)
            self.assertEqual(o.outcome, "hold", (v9, cls))
            self.assertTrue(o.reason.startswith(f"v9:{v9}:"), o.reason)

    def test_current_hard_signals_hold_with_the_current_reason(self):
        cases = [
            ({"gate": account_gate.GateResult("hold", ("x",))}, "account_gate_hold"),
            ({"gate": account_gate.GateResult("allow", ("user on the watchlist",))}, "watchlisted_account"),
            ({"held": ["R8_account_hold"]}, "R8_account_hold"),
            ({"f": facts(rules={**VEL, "reject_artist_credit": 100.0})}, "current_rule:reject_artist_credit"),
            ({"f": facts(rules={**VEL, "review_name_clash": 100.0})}, "current_rule:review_name_clash"),
            ({"v9": None}, "v9_unread"),
            ({"v9": ""}, "v9_unread"),
            ({"f": facts(pop=0)}, "big_or_unknown_popularity"),
            ({"f": facts(pop=60)}, "big_or_unknown_popularity"),
            ({"f": facts(source="client")}, "big_or_unknown_popularity"),
            ({"f": facts(uid=7)}, "user_mismatch"),
            # QA #1539: a stored verdict that did not score every hold rule is not a current-rule clearance
            ({"f": facts(rules={})}, "incomplete_rule_scores"),                       # null / unreadable map
            ({"f": facts(rules={"reject_high_velocity_profile": 100.0})}, "incomplete_rule_scores"),
            ({"f": facts(rules={k: 0.0 for k in sv.REQUIRED_HOLD_RULES[1:]}), "v9": "WAIT"},
             "incomplete_rule_scores"),
            # QA #1539: a hard signal holds BEFORE the V9 branch - a WAIT/DECLINE row never reaches the ask
            ({"f": facts(pop=60), "v9": "WAIT"}, "big_or_unknown_popularity"),
            ({"f": facts(pop=None), "v9": "DECLINE"}, "big_or_unknown_popularity"),
            ({"f": facts(source="client"), "v9": "WAIT"}, "big_or_unknown_popularity"),
        ]
        for kw, want in cases:
            o = self.one(**kw)
            self.assertEqual(o.outcome, "hold", kw)
            self.assertTrue(o.reason.startswith(want), (kw, o.reason))

    def test_owning_the_credited_profile_is_not_a_hold(self):
        """doc-verify 158 / live preview: 855 of the 1,348 rows were held only because their submitter claims the
        credited profile - their own artist/producer page. That is the CLOSE rail (never reject an owner), not a
        reason to withhold the owner's own ask or an ANCHORED person-path release (core does not require it)."""
        for owns in (True, None):
            self.assertEqual(self.one(f=facts(owns=owns), v9="WAIT").outcome, "ask")
            self.assertEqual(self.one(f=facts(owns=owns, rules={**VEL, "reject_high_velocity_profile": 0.0})).outcome,
                             "release_anchored")
        self.assertEqual(self.one(f=facts(owns=True, pop=0), v9="WAIT").outcome, "hold")   # pop still holds

    def test_unreadable_gate_or_hold_set_is_not_green(self):
        def boom(u):
            raise RuntimeError("down")
        rows, _ = sv.evaluate([(R1, 42)], {R1: facts()}, {R1: "WAIT"}, boom, lambda u: [], None,
                              {R1: "person_not_linked"})
        self.assertTrue(rows[0].reason.startswith("account_gate_unknown"))
        rows, _ = sv.evaluate([(R1, 42)], {R1: facts()}, {R1: "WAIT"}, lambda u: ALLOW, boom, None, {R1: "person_not_linked"})
        self.assertTrue(rows[0].reason.startswith("account_hold_unknown"))

    def test_rows_no_longer_pending_get_no_row(self):
        for f, key in ((facts(status="approved"), "not_pending:approved"), (facts(deleted=True), "not_pending:deleted")):
            rows, skipped = run(f=f)
            self.assertEqual((rows, skipped), ([], {key: 1}))
        rows, skipped = sv.evaluate([(R1, 42)], {}, {}, lambda u: ALLOW, lambda u: [], None)
        self.assertEqual(skipped, {"not_pending:missing": 1})

    def test_the_gate_is_read_once_per_user(self):
        calls = []
        r2 = "22222222-2222-4222-8222-222222222222"
        sv.evaluate([(R1, 42), (r2, 42)], {R1: facts(), r2: facts()}, {R1: "WAIT", r2: "WAIT"},
                    lambda u: calls.append(u) or ALLOW, lambda u: [], None, {R1: "person_not_linked", "22222222-2222-4222-8222-222222222222": "person_not_linked"})
        self.assertEqual(calls, [42])


class RecheckTest(unittest.TestCase):
    def test_a_user_who_turns_red_before_the_write_holds_every_row(self):
        r2 = "22222222-2222-4222-8222-222222222222"
        rows, _ = sv.evaluate([(R1, 42), (r2, 9)], {R1: facts(), r2: facts(uid=9)}, {R1: "WAIT", r2: "WAIT"},
                              lambda u: ALLOW, lambda u: [], None, {R1: "person_not_linked", "22222222-2222-4222-8222-222222222222": "person_not_linked"})
        self.assertEqual({o.outcome for o in rows}, {"ask"})
        changed = sv.recheck_before_write(rows, lambda u: ALLOW, lambda u: ["R8_account_hold"] if u == 42 else [])
        self.assertEqual(changed, {42: "R8_account_hold"})
        self.assertEqual({(o.user_id, o.outcome) for o in rows}, {(42, "hold"), (9, "ask")})
        self.assertTrue([o for o in rows if o.user_id == 42][0].reason.startswith("not_green_before_write:R8"))

    def test_a_still_green_user_is_untouched(self):
        rows, _ = run(v9="WAIT")
        self.assertEqual(sv.recheck_before_write(rows, lambda u: ALLOW, lambda u: []), {})
        self.assertEqual(rows[0].outcome, "ask")


class SummaryAndRecordTest(unittest.TestCase):
    def test_summary_counts_by_user_paid_first(self):
        r2 = "22222222-2222-4222-8222-222222222222"
        rows, _ = sv.evaluate([(R1, 42), (r2, 9)], {R1: facts(), r2: facts(uid=9)}, {R1: "WAIT", r2: "WAIT"},
                              lambda u: ALLOW, lambda u: [], frozenset({9}), {R1: "person_not_linked", "22222222-2222-4222-8222-222222222222": "person_not_linked"})
        self.assertEqual([o.user_id for o in rows], [9, 42])           # paid user first
        s = sv.summary(rows)
        self.assertEqual(s["totals"], {"ask": 2})
        self.assertEqual(s["by_user"]["9"], {"ask": 1, "paid": True})

    def test_audit_rows_carry_kind_revalidate_and_the_rule_version_append_only(self):
        d = tempfile.mkdtemp()
        db = sqlite3.connect(f"{d}/ledger.sqlite3")
        rows, _ = run()
        self.assertEqual(sv.record(db, "run-1", "shadow", rows, datetime(2026, 10, 30, tzinfo=timezone.utc)), 1)
        got = db.execute("SELECT decision, evidence_kind, reason_code, mode, rule_version, expected_status, "
                         "evidence_json FROM decisions").fetchone()
        self.assertEqual(got[:4], ("hold", "revalidate", "revalidate_blocked_stale_rule", "shadow"))
        self.assertTrue(got[4].startswith(sv.RULE_ID + "+"))
        self.assertEqual(got[5], "user_verification_needed")
        self.assertEqual(json.loads(got[6])["retired_firing"], ["reject_high_velocity_profile"])
        with self.assertRaises(sqlite3.DatabaseError):
            db.execute("DELETE FROM decisions")

    def dsp(self, verdicts):
        d = tempfile.mkdtemp()
        p = f"{d}/dsp.sqlite"
        con = sqlite3.connect(p)
        con.execute("create table dsp_runs (run_id text, kind text)")
        con.execute("create table dsp_captures (capture_request_id text, request_ids_json text)")
        con.execute("create table dsp_verdicts (id integer primary key, run_id text, request_id text, verdict text, "
                    "reason_class text, capture_request_id text, packet_json text, version text)")
        con.executemany("insert into dsp_runs values (?, ?)", [("v", "verify"), ("e", "eval")])
        con.execute("insert into dsp_captures values ('cap-1', ?)", (json.dumps([R1]),))
        for run, verdict, cap, pcap, ver in verdicts:
            con.execute("insert into dsp_verdicts (run_id, request_id, verdict, reason_class, capture_request_id, "
                        "packet_json, version) values (?,?,?,?,?,?,?)",
                        (run, R1, verdict, verdict.lower(), cap, json.dumps({"capture": {"request_id": pcap}}), ver))
        con.commit()
        return p

    def test_v9_latest_reads_the_newest_self_captured_current_version_verdict(self):
        p = self.dsp([("v", "WAIT", "cap-1", "cap-1", "dsp-1"), ("v", "APPROVE", "cap-1", "cap-1", "dsp-1")])
        self.assertEqual(sv.v9_latest([R1], p, version="dsp-1"), {R1: "APPROVE"})

    def test_eval_old_version_and_foreign_capture_verdicts_never_count(self):
        # the newest row is each kind of non-qualifying APPROVE; the qualifying WAIT under it is what counts
        base = ("v", "WAIT", "cap-1", "cap-1", "dsp-1")
        for bad in (("e", "APPROVE", "cap-1", "cap-1", "dsp-1"),      # eval / caller-supplied packet run
                    ("v", "APPROVE", "cap-1", "cap-1", "dsp-0"),      # an older verifier version
                    ("v", "APPROVE", "cap-9", "cap-9", "dsp-1"),      # a capture this store did not file for R1
                    ("v", "APPROVE", "cap-1", "cap-2", "dsp-1"),      # the packet names another capture
                    ("v", "APPROVE", None, None, "dsp-1")):           # no capture at all
            p = self.dsp([base, bad])
            got = sv.v9_latest([R1], p, version="dsp-1")
            self.assertNotEqual(got.get(R1), "APPROVE", bad)


if __name__ == "__main__":
    unittest.main()
