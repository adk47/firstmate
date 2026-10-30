"""Fable [key=first-awards] path (1): V9 APPROVE -> anchor record -> ANCHORED approve tray, every row citing
dsp_verdicts:<id>, admitted by the executor only while that verdict is the request's latest self-captured APPROVE."""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import anchored_feed as af  # noqa: E402

# a private copy of the executor: test_credit_fable_executor stubs fx.coded_outcome_refusal module-wide
_spec = importlib.util.spec_from_file_location(
    "credit_review._fx_real_for_anchored", Path(__file__).resolve().parents[1] / "credit_review" / "fable_executor.py")
fx = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fx
_spec.loader.exec_module(fx)

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"


def facts(status="unverified", uid=42, pop=30, source="industry", deleted=False):
    return fx.Facts(status=status, user_id=uid, popularity=pop, deleted=deleted, rules={}, metadata_source=source,
                    paid=True, owns_profile=False)


def store(rows):
    """rows: (request_id, verdict, run_kind, version, capture filed for it, packet names it)"""
    d = tempfile.mkdtemp()
    p = f"{d}/dsp.sqlite"
    con = sqlite3.connect(p)
    con.execute("create table dsp_runs (run_id text, kind text)")
    con.execute("create table dsp_captures (capture_request_id text, request_ids_json text)")
    con.execute("create table dsp_verdicts (id integer primary key, run_id text, request_id text, user_id integer, "
                "paid integer, verdict text, capture_request_id text, packet_json text, version text)")
    con.executemany("insert into dsp_runs values (?, ?)", [("v", "verify"), ("e", "eval")])
    for i, (rid, verdict, kind, ver, filed, named) in enumerate(rows):
        cap = f"cap-{i}"
        if filed:
            con.execute("insert into dsp_captures values (?, ?)", (cap, json.dumps([rid])))
        con.execute("insert into dsp_verdicts (run_id, request_id, user_id, paid, verdict, capture_request_id, "
                    "packet_json, version) values (?,?,?,?,?,?,?,?)",
                    ("v" if kind == "verify" else "e", rid, 42, 1, verdict, cap,
                     json.dumps({"capture": {"request_id": cap if named else "other"}}), ver))
    con.commit()
    return p, con


class DspVerdictOutcomeTest(unittest.TestCase):
    def test_only_the_latest_self_captured_current_version_approve_counts(self):
        p, _ = store([(R1, "APPROVE", "verify", "dsp-1", True, True),          # id 1: live
                      (R2, "APPROVE", "verify", "dsp-1", True, True),          # id 2: withdrawn by id 3
                      (R2, "WAIT", "verify", "dsp-1", True, True),             # id 3
                      (R1, "APPROVE", "eval", "dsp-1", True, True),            # id 4: eval run
                      (R2, "APPROVE", "verify", "dsp-0", True, True),          # id 5: old version
                      ("33333333-3333-4333-8333-333333333333", "APPROVE", "verify", "dsp-1", False, True),  # 6
                      ("44444444-4444-4444-8444-444444444444", "APPROVE", "verify", "dsp-1", True, False)])  # 7
        got = fx.dsp_verdict_outcomes([1, 2, 4, 5, 6, 7, 99], p, version="dsp-1")
        self.assertEqual(got["dsp_verdicts:1"], {"request_id": R1, "decision": "approve", "mode": "apply"})
        for vid in (2, 4, 5, 6, 7):
            self.assertEqual(got[f"dsp_verdicts:{vid}"]["decision"], "none", vid)
        self.assertNotIn("dsp_verdicts:99", got)
        self.assertEqual(fx.dsp_verdict_outcomes([1], "/nonexistent/x.sqlite", version="dsp-1"), {})

    def test_the_executor_admits_an_approve_tray_row_only_on_a_live_approve(self):
        p, _ = store([(R1, "APPROVE", "verify", "dsp-1", True, True)])
        d = tempfile.mkdtemp()
        doc = {"action": "approve", "expected_status": "unverified", "rows": [{
            "request_id": R1, "user_id": 42, "coded_outcome": "dsp_verdicts:1", "ruling_id": "dsp_verdicts-1",
            "rule": af.RULE_ID, "paid": True, "evidence": "V9 APPROVE: same-run Spotify and Tidal credit the claimant"}]}
        Path(f"{d}/t.json").write_text(json.dumps(doc))
        tray = fx.load_tray(f"{d}/t.json")
        oc = fx.dsp_verdict_outcomes([1], p, version="dsp-1")
        self.assertIsNone(fx.coded_outcome_refusal(tray, tray.rows[0], oc))
        oc["dsp_verdicts:1"]["decision"] = "none"
        self.assertEqual(fx.coded_outcome_refusal(tray, tray.rows[0], oc), "coded_outcome_decision:none")


class FeedTest(unittest.TestCase):
    def run_feed(self, cands, oc=None, fm=None, built=None, handled=(), limit=1):
        oc = oc if oc is not None else {f"dsp_verdicts:{c.verdict_id}": {"request_id": c.request_id,
                                                                         "decision": "approve", "mode": "apply"}
                                        for c in cands}
        fm = fm if fm is not None else {c.request_id: facts() for c in cands}
        seen = []

        def build(cs):
            seen.append([c.request_id for c in cs])
            return built if built is not None else {c.request_id: "built" for c in cs}
        return af.feed(cands, outcomes=lambda ids: oc, facts=lambda ids: fm, build=build, handled=set(handled),
                       limit=limit), seen

    def test_one_live_approve_becomes_one_tray_row_citing_its_verdict(self):
        res, seen = self.run_feed([af.Candidate(7, R1, 42, True)])
        self.assertEqual(seen, [[R1]])
        row = res.trays["unverified"]["rows"][0]
        self.assertEqual((row["coded_outcome"], row["ruling_id"], row["rule"]), ("dsp_verdicts:7", "dsp_verdicts-7",
                                                                                af.RULE_ID))
        self.assertEqual(res.trays["unverified"]["action"], "approve")

    def test_every_guard_skips_and_nothing_is_built_for_it(self):
        c = af.Candidate(7, R1, 42, True)
        cases = [
            (dict(handled=[R1]), "already_fed"),
            (dict(oc={}), "verdict_not_a_live_self_captured_approve"),
            (dict(oc={"dsp_verdicts:7": {"request_id": R1, "decision": "none", "mode": "apply"}}),
             "verdict_not_a_live_self_captured_approve"),
            (dict(fm={R1: facts(status="approved")}), "not_open"),
            (dict(fm={R1: facts(deleted=True)}), "not_open"),
            (dict(fm={}), "not_open"),
            (dict(fm={R1: facts(uid=7)}), "user_mismatch"),
            (dict(fm={R1: facts(pop=0)}), "big_or_unknown_popularity"),
            (dict(fm={R1: facts(pop=60)}), "big_or_unknown_popularity"),
            (dict(fm={R1: facts(source="client")}), "big_or_unknown_popularity"),
        ]
        for kw, want in cases:
            res, seen = self.run_feed([c], **kw)
            self.assertEqual((res.skipped, res.trays, seen), ({want: 1}, {}, []), kw)

    def test_a_refused_anchor_build_never_reaches_a_tray(self):
        res, _ = self.run_feed([af.Candidate(7, R1, 42, True)], built={R1: "refused:verdict is WAIT"})
        self.assertEqual((res.trays, res.skipped), ({}, {"anchor_not_built": 1}))

    def test_the_limit_holds_and_paid_order_is_kept(self):
        cands = [af.Candidate(1, R1, 42, True), af.Candidate(2, R2, 42, False)]
        res, seen = self.run_feed(cands, limit=1)
        self.assertEqual((seen, res.skipped), ([[R1]], {"over_limit_next_run": 1}))

    def test_candidates_read_the_latest_verify_verdict_only(self):
        _p, con = store([(R1, "APPROVE", "verify", "dsp-1", True, True), (R1, "WAIT", "verify", "dsp-1", True, True),
                         (R2, "APPROVE", "verify", "dsp-1", True, True), (R2, "WAIT", "eval", "dsp-1", True, True)])
        self.assertEqual([(c.verdict_id, c.request_id) for c in af.approve_candidates(con)], [(3, R2)])

    def test_already_handled_reads_approve_audit_lines_only(self):
        lines = [{"action": "approve", "outcome": "reserved", "request_id": R1.upper()},
                 {"outcome": "written", "request_id": R2}]
        self.assertEqual(af.already_handled(lines), {R1})


if __name__ == "__main__":
    unittest.main()
