"""L12 claim route (Fable claim-route-zero): tray validation, every guard, write / read-back / audit / stop rules."""
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import account_gate  # noqa: E402
from credit_review import claim_executor as cx  # noqa: E402

NOW = datetime(2026, 10, 29, 3, 0, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow", ("no account-level signal",), {"decision": "allow"})
PID = "35e96343-94d2-4e76-89c5-3b269cf02070"


def row(cid=1607654, **kw):
    r = {"claim_id": cid, "user_id": 1398875, "profile_id": PID, "profile_type": "organization",
         "ruling_id": "claim-route-zero", "contradiction": "individual_claims_company",
         "evidence": "Pinkfong as the company of a 1-day gmail account who also claims Bob Gaudio",
         "audit_reason": "STD org text"}
    r.update(kw)
    return r


def facts(**kw):
    d = dict(status="pending", user_id=1398875, profile_id=PID, profile_type="organization",
             reason="company claim on add", deleted=False)
    d.update(kw)
    return cx.ClaimFacts(**d)


class TrayTest(unittest.TestCase):
    def load(self, doc):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(doc, fh)
        return cx.load_claim_tray(fh.name)

    def test_valid_tray_loads(self):
        t = self.load({"action": "reject_claim", "rows": [row()]})
        self.assertEqual(t.rows[0].claim_id, 1607654)

    def test_refusals(self):
        bad = [
            ({"action": "reject", "rows": [row()]}, "action"),
            ({"action": "reject_claim", "rows": []}, "non-empty"),
            ({"action": "reject_claim", "rows": [row(ruling_id="")]}, "ruling"),
            ({"action": "reject_claim", "rows": [row(contradiction="name_only")]}, "contradiction"),
            ({"action": "reject_claim", "rows": [row(contradiction=None)]}, "contradiction"),
            ({"action": "reject_claim", "rows": [row(evidence="short")]}, "evidence"),
            ({"action": "reject_claim", "rows": [row(), row()]}, "duplicate"),
            ({"action": "reject_claim", "rows": [row(claim_id="1")]}, "claim_id"),
            ({"action": "reject_claim", "rows": [row(profile_type="")]}, "profile"),
            ({"action": "reject_claim", "daily_cap": 400, "rows": [row()]}, "daily_cap"),
        ]
        for doc, msg in bad:
            with self.assertRaisesRegex(cx.TrayError, msg):
                self.load(doc)


class GuardTest(unittest.TestCase):
    R = cx.ClaimRow(1607654, 1398875, PID, "organization", "claim-route-zero", "individual_claims_company",
                    "x" * 30)

    def test_allows_a_clean_open_claim(self):
        self.assertIsNone(cx.refusal(self.R, facts(), ALLOW))
        self.assertIsNone(cx.refusal(self.R, facts(status="reverted"), ALLOW))

    def test_each_guard(self):
        cases = [
            (None, ALLOW, "claim_not_found"),
            (facts(deleted=True), ALLOW, "claim_deleted"),
            (facts(status="processed"), ALLOW, "status_changed"),
            (facts(status="rejected"), ALLOW, "status_changed"),
            (facts(user_id=7), ALLOW, "user_mismatch"),
            (facts(profile_id="other"), ALLOW, "profile_mismatch"),
            (facts(profile_type="artist"), ALLOW, "profile_type_changed"),
            (facts(reason="created by user"), ALLOW, "created_by_user_claim"),
            (facts(reason="  Created By User "), ALLOW, "created_by_user_claim"),
            (facts(), account_gate.GateResult("hold", ("x",), {}), "account_gate_hold"),
            (facts(), account_gate.GateResult("unknown", ("x",), {}), "account_gate_unknown"),
            (facts(), account_gate.GateResult("allow", ("AMBER watchlist review-local",), {"decision": "allow"}),
             "watchlisted_account"),
        ]
        for f, g, want in cases:
            self.assertTrue((cx.refusal(self.R, f, g) or "").startswith(want), (f, g, want))


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.audit = str(self.tmp / "audit.jsonl")
        self.registry = self.tmp / "registry.json"
        self.registry.write_text(json.dumps({"automations": {"fable-decider": {
            "approved": True, "approved_by": "captain", "approval_ref": "captain-1028-213x"}}}))
        self.kill = str(self.tmp / "kill")
        self.calls = []
        self.state = {}

    def tray(self, n=3):
        rows = tuple(cx.ClaimRow(1000 + i, 1398875, PID, "organization", "claim-route-zero",
                                 "individual_claims_company", "x" * 30) for i in range(n))
        return cx.ClaimTray(str(self.tmp / "t.json"), "0" * 64, rows, 100)

    def facts_fn(self, ids):
        return {i: facts(status=self.state.get(i, "pending")) for i in ids}

    def writer(self, cid, ruling, run_id, tray_path):
        self.calls.append(cid)
        self.state[cid] = "rejected"
        return {}

    def go(self, t, **kw):
        args = dict(apply=True, facts_fn=self.facts_fn, gate_fn=lambda u: ALLOW, writer=self.writer,
                    audit_path=self.audit, registry_path=str(self.registry), kill_file=self.kill,
                    lock_path=str(self.tmp / "lock"), now=lambda: NOW, sleep=lambda s: None)
        args.update(kw)
        return cx.run(t, **args)

    def lines(self):
        return [json.loads(l) for l in Path(self.audit).read_text().splitlines()]

    def test_writes_reads_back_and_audits_each_claim(self):
        res = self.go(self.tray())
        self.assertEqual((res.written, res.stopped), (3, ""))
        self.assertEqual(self.calls, [1000, 1001, 1002])
        outs = [l["outcome"] for l in self.lines()]
        self.assertEqual(outs, ["reserved", "written"] * 3)
        self.assertTrue(all(l["request_id"].startswith("claim:") and l["ruling_id"] == "claim-route-zero"
                            for l in self.lines()))

    def test_dry_run_writes_nothing(self):
        res = cx.run(self.tray(), apply=False, facts_fn=self.facts_fn, gate_fn=lambda u: ALLOW)
        self.assertEqual((self.calls, res.refused), ([], {"would_write": 3}))

    def test_refused_claim_is_skipped_and_audited(self):
        self.state[1001] = "processed"
        res = self.go(self.tray())
        self.assertEqual(self.calls, [1000, 1002])
        self.assertEqual(res.refused, {"status_changed": 1})

    def test_kill_file_registry_and_cap_stop_before_any_write(self):
        Path(self.kill).write_text("")
        self.assertIn("kill file", self.go(self.tray()).stopped)
        Path(self.kill).unlink()
        self.registry.write_text(json.dumps({"automations": {"fable-decider": {"approved": False}}}))
        self.assertIn("not approved", self.go(self.tray()).stopped)
        self.assertEqual(self.calls, [])

    def test_cap_shared_with_credit_closes(self):
        with open(self.audit, "w") as fh:
            for i in range(99):
                fh.write(json.dumps({"ts": "2026-10-29T01:00:00Z", "run_id": "c", "outcome": "written",
                                     "request_id": f"credit-{i}"}) + "\n")
        res = self.go(self.tray())
        self.assertEqual(self.calls, [1000])
        self.assertIn("daily cap", res.stopped)

    def test_not_moved_stops(self):
        def lazy(cid, *a):
            self.calls.append(cid)
            return {}
        res = self.go(self.tray(), writer=lazy)
        self.assertEqual((self.calls, res.not_moved), ([1000], 1))
        self.assertIn("not rejected", res.stopped)

    def test_failed_write_stops_and_is_audited(self):
        def boom(cid, *a):
            self.calls.append(cid)
            raise RuntimeError("HTTP 409")
        res = self.go(self.tray(), writer=boom)
        self.assertEqual(self.calls, [1000])
        self.assertIn("write failed", res.stopped)
        self.assertEqual([l["outcome"] for l in self.lines()], ["reserved", "not_moved"])

    def test_readback_waits_for_the_replica(self):
        reads = {"n": 0}

        def lagging(ids):
            reads["n"] += 1
            return {i: facts(status=("rejected" if (i in self.state and reads["n"] > 3) else "pending")) for i in ids}
        res = self.go(self.tray(1), facts_fn=lagging)
        self.assertEqual(res.written, 1)

    def test_unwritable_audit_sends_nothing(self):
        bad = self.tmp / "f"
        bad.write_text("x")
        res = self.go(self.tray(), audit_path=str(bad / "a.jsonl"))
        self.assertEqual(self.calls, [])
        self.assertIn("audit/lock failure", res.stopped)

    def test_fanout_surprise_stops(self):
        res = self.go(self.tray(), after_batch=lambda moved, since: "over")
        self.assertIn("fan-out", res.stopped)

    def test_limit(self):
        res = self.go(self.tray(), limit=1)
        self.assertEqual((self.calls, res.written), ([1000], 1))
        for bad in (0, -1, True):
            with self.assertRaises(ValueError):
                self.go(self.tray(), limit=bad)

    def test_post_carries_no_reason(self):
        import subprocess as sp
        seen = {}

        def fake_run(argv, **kw):
            seen["argv"] = argv
            return sp.CompletedProcess(argv, 0, json.dumps({"http_status": 200, "body": {}}), "")
        orig = cx.subprocess.run
        cx.subprocess.run = fake_run
        try:
            cx.admin_claim_writer(script="/x.sh")(1607654, "claim-route-zero", "r1", "/t.json")
        finally:
            cx.subprocess.run = orig
        self.assertEqual(seen["argv"][-3:], ["POST", "/admin/claiming/1607654/reject", "{}"])


if __name__ == "__main__":
    unittest.main()
