"""L12 executor (credit_review.fable_executor): tray validation, write-boundary guards, cap, kill file, audit.

Hermetic: no Trino, no gate binary, no admin API, no /etc or /var paths. Each guard has a test that turns red
if the guard is removed (the "red mutant" contract of the Fable exec plan, section a).
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402

RID = "11111111-1111-4111-8111-111111111111"
RID2 = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 10, 28, 22, 0, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow", ("no account-level signal",), {"decision": "allow"})


def facts(**over) -> fx.Facts:
    base = dict(status="unverified", user_id=42, popularity=30, deleted=False,
                rules={"reject_publisher_label_credit": 100.0}, metadata_source="industry", paid=True,
                profile_id="p1")
    base.update(over)
    return fx.Facts(**base)


def row(**over) -> fx.TrayRow:
    base = dict(request_id=RID, user_id=42, ruling_id="u10k-3", rule="reject_publisher_label_credit", paid=True)
    base.update(over)
    return fx.TrayRow(**base)


class TrayTest(unittest.TestCase):
    def write(self, doc) -> str:
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f)
        f.close()
        return f.name

    def tray(self, **over):
        doc = {"action": "reject", "expected_status": "unverified",
               "rows": [{"request_id": RID, "user_id": 42, "ruling_id": "u10k-3",
                         "rule": "reject_publisher_label_credit", "paid": False},
                        {"request_id": RID2, "user_id": "7", "ruling_id": "u10k-3",
                         "rule": "reject_artist_credit", "paid": True}]}
        doc.update(over)
        return doc

    def test_valid_tray_loads_paid_first(self):
        t = fx.load_tray(self.write(self.tray()))
        self.assertEqual([r.request_id for r in t.rows], [RID2, RID])
        self.assertEqual(t.daily_cap, 100)
        self.assertEqual(len(t.sha256), 64)

    def test_one_row_without_a_ruling_id_refuses_the_whole_tray(self):
        doc = self.tray()
        del doc["rows"][1]["ruling_id"]
        with self.assertRaisesRegex(fx.TrayError, "ruling id"):
            fx.load_tray(self.write(doc))

    def test_only_reject_actions_are_executable(self):
        for action in ("approve", "delete", None):
            with self.assertRaisesRegex(fx.TrayError, "not executable"):
                fx.load_tray(self.write(self.tray(action=action)))

    def test_approved_rows_can_never_be_the_expected_status(self):
        with self.assertRaisesRegex(fx.TrayError, "expected_status"):
            fx.load_tray(self.write(self.tray(expected_status="approved")))

    def test_rule_must_be_a_validator_reject_or_a_fable_rule_with_evidence(self):
        doc = self.tray()
        doc["rows"][0]["rule"] = "risk_score"
        with self.assertRaisesRegex(fx.TrayError, "neither"):
            fx.load_tray(self.write(doc))
        doc["rows"][0]["rule"] = "R-C2(4)"
        with self.assertRaisesRegex(fx.TrayError, "evidence"):
            fx.load_tray(self.write(doc))
        doc["rows"][0]["evidence"] = "Bass credited to Pablo Cesar Rodriguez on a complete Spotify snapshot"
        self.assertEqual(fx.load_tray(self.write(doc)).rows[1].rule, "R-C2(4)")

    def test_duplicate_or_malformed_ids_refuse_the_tray(self):
        doc = self.tray()
        doc["rows"][1]["request_id"] = RID
        with self.assertRaisesRegex(fx.TrayError, "duplicate"):
            fx.load_tray(self.write(doc))
        doc["rows"][1]["request_id"] = "not-a-uuid"
        with self.assertRaisesRegex(fx.TrayError, "UUID"):
            fx.load_tray(self.write(doc))

    def test_a_cap_above_100_needs_a_cap_ruling_and_400_is_the_ceiling(self):
        with self.assertRaisesRegex(fx.TrayError, "cap_ruling_id"):
            fx.load_tray(self.write(self.tray(daily_cap=400)))
        t = fx.load_tray(self.write(self.tray(daily_cap=400, cap_ruling_id="confirms-captain-1028-214x")))
        self.assertEqual(t.daily_cap, 400)
        with self.assertRaisesRegex(fx.TrayError, "1..400"):
            fx.load_tray(self.write(self.tray(daily_cap=401, cap_ruling_id="x-ruling")))


class FraudDenyPassthroughTest(unittest.TestCase):
    def test_fraud_pair_and_signal_ids_reach_the_audit_verbatim(self):
        pair = [{"id": "sig-a", "family": "font", "fields": ["date"], "page": 1, "region": [10, 20, 30, 40]},
                {"id": "sig-b", "family": "metadata", "fields": ["producer"], "page": 1, "region": None}]
        doc = {"action": "reject", "expected_status": "unverified", "rows": [{
            "request_id": RID, "user_id": 42, "ruling_id": "forged-ab12cd34", "rule": "R-FRAUD-DOC",
            "evidence": "proof sha256 ff00 forged: font + metadata families", "reason_code": "fraud_document",
            "proof_id": "ff00", "fraud_pair": pair, "signal_ids": ["sig-a", "sig-b"], "outcome_ids": [7, 8],
            "subject": "credit"}]}
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f)
        f.close()
        tray = fx.load_tray(f.name)
        tmp = Path(tempfile.mkdtemp())
        reg = tmp / "r.json"
        reg.write_text(json.dumps({"automations": {"fable-decider": {"approved": True, "approved_by": "c",
                                                                       "approval_ref": "x"}}}))
        fx.run(tray, apply=True, facts_fn=lambda ids: {RID: facts(rules={})}, gate_fn=lambda u: ALLOW,
               writer=lambda ids, e, r, run, tp: {"updatedIds": ids}, readback=lambda s, ids: set(ids),
               audit_path=str(tmp / "a.jsonl"), registry_path=str(reg), kill_file=str(tmp / "k"), now=lambda: NOW,
               lock_path=str(tmp / "lock"))
        line = [json.loads(l) for l in (tmp / "a.jsonl").read_text().splitlines()][-1]
        self.assertEqual(line["fraud_pair"], pair)
        self.assertEqual((line["signal_ids"], line["reason_code"], line["ruling_id"]),
                         (["sig-a", "sig-b"], "fraud_document", "forged-ab12cd34"))


class GuardTest(unittest.TestCase):
    """Each guard: the clean row passes; one changed fact refuses it."""

    def refuse(self, f, gate=ALLOW, r=None):
        return fx.refusal(r or row(), f, gate, "unverified")

    def test_clean_row_passes(self):
        self.assertIsNone(self.refuse(facts()))

    def test_missing_or_deleted_row(self):
        self.assertEqual(self.refuse(None), "row_not_found")
        self.assertEqual(self.refuse(facts(deleted=True)), "row_deleted")

    def test_status_changed_since_the_ruling(self):
        self.assertEqual(self.refuse(facts(status="approved")), "status_changed:approved")

    def test_row_belongs_to_another_user(self):
        self.assertEqual(self.refuse(facts(user_id=43)), "user_mismatch")

    def test_cited_validator_rule_no_longer_fires(self):
        self.assertTrue(self.refuse(facts(rules={"reject_publisher_label_credit": 0.0})).startswith("rule_not_firing"))
        self.assertTrue(self.refuse(facts(rules={})).startswith("rule_not_firing"))

    def test_fable_rule_rows_do_not_need_a_validator_rule(self):
        r = row(rule="R-C2(4)", evidence="one-person role credited to somebody else, complete snapshot")
        self.assertIsNone(self.refuse(facts(rules={}), r=r))

    def test_big_or_unknown_popularity(self):
        for pop in (60, 85, 0, None):
            self.assertTrue(self.refuse(facts(popularity=pop)).startswith("big_or_unknown_popularity"), pop)
        self.assertTrue(self.refuse(facts(metadata_source="client")).startswith("big_or_unknown_popularity"))

    def test_account_gate_must_allow(self):
        for decision in ("hold", "unknown"):
            g = account_gate.GateResult(decision, ("x",), {})
            self.assertEqual(self.refuse(facts(), gate=g), f"account_gate_{decision}")

    def test_watchlisted_account(self):
        g = account_gate.GateResult("allow", ("AMBER watchlist review-local",), {"decision": "allow"})
        self.assertEqual(self.refuse(facts(), gate=g), "watchlisted_account")
        g = account_gate.GateResult("allow", (), {"decision": "allow", "watch": {"list": "deny"}})
        self.assertEqual(self.refuse(facts(), gate=g), "watchlisted_account")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.audit = str(self.tmp / "audit.jsonl")
        self.kill = str(self.tmp / "fable-decider.disabled")
        self.registry = str(self.tmp / "registry.json")
        self.set_registry(True)
        self.calls = []

    def set_registry(self, approved):
        Path(self.registry).write_text(json.dumps({"automations": {"fable-decider": {
            "approved": approved, "approved_by": "captain", "approval_ref": "captain-1028-213x"}}}))

    def tray(self, n=2, cap=100):
        ids = [f"{i:08d}-1111-4111-8111-111111111111" for i in range(n)]
        rows = tuple(fx.TrayRow(i, 42, "u10k-3", "reject_publisher_label_credit", True) for i in ids)
        return fx.Tray("tray.json", "0" * 64, "reject", "unverified", rows, cap, None)

    def go(self, tray, *, apply=True, facts_map=None, gate=ALLOW, writer=None, landed=None, **kw):
        fm = facts_map if facts_map is not None else {r.request_id: facts() for r in tray.rows}

        def write(ids, expected, ruling, run_id, tray_path):
            self.calls.append((list(ids), expected, ruling))
            return {"updatedIds": ids}

        def readback(status, ids):
            self.assertEqual(status, "rejected")
            return set(ids) if landed is None else set(ids) & landed
        return fx.run(tray, apply=apply, facts_fn=lambda ids: {i: fm[i] for i in ids if i in fm},
                      gate_fn=lambda u: gate, writer=writer or write, readback=readback,
                      audit_path=self.audit, registry_path=self.registry, kill_file=self.kill,
                      now=lambda: NOW, lock_path=str(self.tmp / "lock"), **kw)

    def audit_lines(self):
        return [json.loads(l) for l in Path(self.audit).read_text().splitlines()] if Path(self.audit).exists() else []

    def test_dry_run_writes_nothing_and_counts_would_write(self):
        res = self.go(self.tray(), apply=False)
        self.assertEqual(self.calls, [])
        self.assertEqual(res.refused, {"would_write": 2})
        self.assertEqual(self.audit_lines(), [])

    def test_apply_writes_with_the_ruling_reads_back_and_audits_every_row(self):
        res = self.go(self.tray())
        self.assertEqual((res.written, res.stopped), (2, ""))
        self.assertEqual(self.calls[0][1:], ("unverified", "u10k-3"))
        lines = self.audit_lines()
        self.assertEqual([l["outcome"] for l in lines], ["reserved", "reserved", "written", "written"])
        self.assertTrue(all(l["ruling_id"] == "u10k-3" for l in lines))
        self.assertTrue(all(l["after"] == "rejected" for l in lines if l["outcome"] == "written"))

    def test_refused_rows_are_audited_and_never_sent(self):
        t = self.tray()
        fm = {t.rows[0].request_id: facts(popularity=80), t.rows[1].request_id: facts()}
        res = self.go(t, facts_map=fm)
        self.assertEqual(self.calls[0][0], [t.rows[1].request_id])
        self.assertEqual(res.refused, {"big_or_unknown_popularity": 1})
        self.assertEqual([l["outcome"] for l in self.audit_lines()], ["refused", "reserved", "written"])

    def test_kill_file_stops_before_any_write(self):
        Path(self.kill).write_text("stop")
        res = self.go(self.tray())
        self.assertEqual(self.calls, [])
        self.assertIn("kill file", res.stopped)

    def test_registry_not_approved_stops_before_any_write(self):
        self.set_registry(False)
        res = self.go(self.tray())
        self.assertEqual(self.calls, [])
        self.assertIn("not approved", res.stopped)

    def test_daily_cap_counts_todays_written_rows(self):
        with open(self.audit, "w") as fh:
            for _ in range(99):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "outcome": "written"}) + "\n")
            fh.write(json.dumps({"ts": "2026-10-27T23:00:00Z", "outcome": "written"}) + "\n")
        res = self.go(self.tray(n=3))
        self.assertEqual(len(self.calls[0][0]), 1)
        self.assertEqual(res.written, 1)
        self.assertIn("daily cap", res.stopped)

    def test_a_row_not_moved_after_a_2xx_stops_the_run(self):
        t = self.tray(n=3)
        res = self.go(t, landed={t.rows[0].request_id})
        self.assertEqual((res.written, res.not_moved), (1, 2))
        self.assertIn("first surprise", res.stopped)

    def test_a_failed_write_stops_and_audits_what_read_back_says(self):
        def boom(ids, expected, ruling, run_id, tray_path):
            raise RuntimeError("PUT refused/failed rc=1: MUSO_CREDIT_REJECT_APPROVAL_REQUIRED")
        t = self.tray()
        res = self.go(t, writer=boom, landed=set())
        self.assertIn("write failed", res.stopped)
        self.assertEqual([l["outcome"] for l in self.audit_lines()], ["reserved", "reserved", "not_moved", "not_moved"])

    def test_batches_are_at_most_100_and_the_fanout_check_runs_between_them(self):
        seen = []
        res = self.go(self.tray(n=150, cap=400), between_batches=lambda rows, since: seen.append(len(rows)))
        self.assertEqual([len(c[0]) for c in self.calls], [100, 50])
        self.assertEqual(seen, [100, 50])
        self.assertEqual(res.written, 150)

    def test_a_fanout_surprise_stops_after_that_batch(self):
        res = self.go(self.tray(n=150, cap=400), between_batches=lambda rows, since: "2 notes for user 42")
        self.assertEqual(len(self.calls), 1)
        self.assertIn("fan-out", res.stopped)


class QaFixTest(RunTest):
    """QA NO-GO on f5ec0da0: per-batch fresh guards, cap lock, audit before PUT; plus the junk-b1 DSP anchor guard."""

    def test_facts_and_gate_are_re_read_for_every_batch(self):
        t = self.tray(n=150, cap=400)
        late = t.rows[120].request_id
        calls = {"facts": 0}

        def facts_fn(ids):
            calls["facts"] += 1
            # after batch 1 wrote, row 120 turned big: the second batch must see it
            return {i: (facts(popularity=80) if (i == late and calls["facts"] > 1) else facts()) for i in ids}
        res = fx.run(t, apply=True, facts_fn=facts_fn, gate_fn=lambda u: ALLOW,
                     writer=lambda ids, e, r, run, tp: {"updatedIds": ids}, readback=lambda s_, ids: set(ids),
                     audit_path=self.audit, registry_path=self.registry, kill_file=self.kill, now=lambda: NOW,
                     lock_path=str(self.tmp / "lock"))
        self.assertGreaterEqual(calls["facts"], 2)
        self.assertEqual(res.refused, {"big_or_unknown_popularity": 1})
        self.assertEqual(res.written, 149)

    def test_an_unwritable_audit_sends_nothing(self):
        bad = self.tmp / "not-a-dir"
        bad.write_text("x")
        self.audit = str(bad / "a.jsonl")      # parent is a regular file: every append fails
        res = self.go(self.tray())
        self.assertEqual(self.calls, [])
        self.assertIn("audit/lock failure", res.stopped)

    def test_reservations_count_against_the_cap_even_without_a_final_line(self):
        with open(self.audit, "w") as fh:
            for i in range(100):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "outcome": "reserved", "request_id": f"r{i}",
                                     "run_id": "x"}) + "\n")
        res = self.go(self.tray())
        self.assertEqual(self.calls, [])
        self.assertIn("daily cap", res.stopped)

    def test_a_held_lock_blocks_the_write(self):
        import fcntl as _f
        lock = self.tmp / "lock"
        fh = open(lock, "a+")
        _f.flock(fh.fileno(), _f.LOCK_EX)
        orig = fx._locked
        fx._locked = lambda path, wait_s=600: orig(path, wait_s=0.2)
        try:
            res = self.go(self.tray())
        finally:
            fx._locked = orig
            fh.close()
        self.assertEqual(self.calls, [])
        self.assertIn("busy", res.stopped)

    def test_dsp_anchor_guard_refuses_anchored_and_unknown_rows(self):
        t = self.tray(n=3)
        t = fx.Tray(t.path, t.sha256, t.action, t.expected_status, t.rows, t.daily_cap, None, True)
        ids = [r.request_id for r in t.rows]
        state = {ids[0]: "anchor", ids[1]: "no_anchor"}            # ids[2]: no verdict = unknown
        res = self.go(t, anchor_fn=lambda xs: {x.lower(): state.get(x, "unknown") for x in xs})
        self.assertEqual(self.calls[0][0], [ids[1]])
        self.assertEqual(res.refused, {"dsp_anchor_present": 1, "dsp_anchor_unknown": 1})

    def test_dsp_store_missing_reads_unknown(self):
        self.assertEqual(fx.dsp_anchors(["AbC"], path=str(self.tmp / "nope.sqlite")), {"abc": "unknown"})

    def test_as_listed_order_is_kept(self):
        doc = {"action": "reject", "expected_status": "unverified", "order": "as_listed", "rows": [
            {"request_id": RID2, "user_id": 9, "ruling_id": "junk-b1", "rule": "reject_x", "paid": False},
            {"request_id": RID, "user_id": 1, "ruling_id": "junk-b1", "rule": "reject_x", "paid": True}]}
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f)
        f.close()
        self.assertEqual([r.request_id for r in fx.load_tray(f.name).rows], [RID2, RID])


class CliBoundaryTest(unittest.TestCase):
    """The exact argv the wrapper sends (muso-admin-api.sh fable_decider_verify_batch) must parse and reach
    verify_batch; a parse error there would refuse every genuine close."""

    def test_wrapper_argv_reaches_verify_batch(self):
        import subprocess
        cli = Path(__file__).resolve().parents[1] / "credit-fable-execute.py"
        wrapper = (Path(__file__).resolve().parents[2] / "workspaces/operations/skills/muso-ops-admin/scripts"
                   / "muso-admin-api.sh").read_text()
        for flag in ("--verify-batch", "--tray", "--ruling", "--run-id", "--expected", "--ids"):
            self.assertIn(flag, wrapper)
        with tempfile.TemporaryDirectory() as d:
            out = subprocess.run([sys.executable, str(cli), "--verify-batch", "--tray", f"{d}/none.json",
                                  "--ruling", "u10k-3", "--run-id", "r1", "--expected", "unverified", "--ids", RID],
                                 capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 3, out.stderr)                 # parsed, then refused by verify_batch
        self.assertIn("fable_decider boundary: tray unusable", out.stderr)

    def test_limit_zero_is_a_usage_error(self):
        import subprocess
        cli = Path(__file__).resolve().parents[1] / "credit-fable-execute.py"
        out = subprocess.run([sys.executable, str(cli), "x.json", "--apply", "--limit", "0"],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 2)
        self.assertIn("--limit must be >= 1", out.stderr)


class QaRound2Test(RunTest):
    """QA NO-GO on 7054fac4: paid-first across rulings, --limit validation, the wrapper boundary check."""

    def test_paid_first_holds_across_rulings_at_the_cap(self):
        mk = lambda i, paid, ruling: fx.TrayRow(f"{i:08d}-1111-4111-8111-111111111111", 42, ruling,
                                                "reject_publisher_label_credit", paid)
        rows = (mk(0, True, "A"), mk(1, True, "B"), *[mk(i, False, "A") for i in range(2, 101)])
        t = fx.Tray("t.json", "0" * 64, "reject", "unverified", tuple(sorted(rows, key=lambda r: (not r.paid,))), 2)
        res = self.go(t)
        written = [i for c in self.calls for i in c[0]]
        self.assertEqual(written, [rows[0].request_id, rows[1].request_id])   # both paid rows, rulings A then B
        self.assertEqual([c[2] for c in self.calls], ["A", "B"])
        self.assertIn("daily cap", res.stopped)

    def test_limit_must_be_positive(self):
        for bad in (0, -1, True):
            with self.assertRaisesRegex(ValueError, "positive"):
                self.go(self.tray(), limit=bad)
        self.assertEqual(self.calls, [])

    def _verify(self, t_path, ids, run_id="run1", ruling="u10k-3", expected="unverified", **kw):
        return fx.verify_batch(t_path, ruling, run_id, ids, expected,
                               facts_fn=kw.get("facts_fn", lambda xs: {x: facts() for x in xs}),
                               gate_fn=lambda u: kw.get("gate", ALLOW), anchor_fn=lambda xs: {},
                               audit_path=self.audit, now=lambda: NOW)

    def _tray_file(self):
        doc = {"action": "reject", "expected_status": "unverified", "rows": [
            {"request_id": RID, "user_id": 42, "ruling_id": "u10k-3", "rule": "reject_publisher_label_credit"}]}
        p = self.tmp / "tray.json"
        p.write_text(json.dumps(doc))
        return str(p), fx.load_tray(str(p)).sha256

    def _reserve(self, sha, run_id="run1", ts="2026-10-28T21:58:00Z", rid=RID):
        with open(self.audit, "a") as fh:
            fh.write(json.dumps({"ts": ts, "run_id": run_id, "outcome": "reserved", "request_id": rid,
                                 "tray_sha256": sha}) + "\n")

    def test_boundary_allows_a_reserved_batch_that_passes_the_guards(self):
        path, sha = self._tray_file()
        self._reserve(sha)
        self.assertIsNone(self._verify(path, [RID]))

    def test_boundary_refuses_a_caller_that_skipped_the_executor(self):
        path, sha = self._tray_file()
        self.assertIn("audit unreadable", self._verify(path, [RID]))                # no audit file: refused
        self._reserve(sha, rid=RID2)
        self.assertIn("no fresh reservation", self._verify(path, [RID]))            # no reservation for this id
        self._reserve(sha, ts="2026-10-28T21:00:00Z")
        self.assertIn("no fresh reservation", self._verify(path, [RID]))            # stale (> 10 min)
        self._reserve(sha, run_id="other")
        self.assertIn("no fresh reservation", self._verify(path, [RID]))            # another run's reservation
        self._reserve(sha)
        self.assertIn("not in the tray", self._verify(path, [RID2]))                 # id outside the tray
        self.assertIn("not under ruling", self._verify(path, [RID], ruling="x-other"))
        self.assertIn("expectedStatus", self._verify(path, [RID], expected="user_verification_needed"))
        self.assertIn("tray unusable", self._verify(str(self.tmp / "nope.json"), [RID]))

    def test_boundary_re_runs_the_row_guards(self):
        path, sha = self._tray_file()
        self._reserve(sha)
        self.assertIn("big_or_unknown_popularity",
                      self._verify(path, [RID], facts_fn=lambda xs: {x: facts(popularity=90) for x in xs}))
        self.assertIn("account_gate_hold",
                      self._verify(path, [RID], gate=account_gate.GateResult("hold", (), {})))

    def test_boundary_enforces_the_daily_cap(self):
        path, sha = self._tray_file()
        for i in range(100):
            self._reserve(sha, run_id=f"r{i}", rid=f"x{i}")
        self._reserve(sha)
        self.assertIn("daily cap", self._verify(path, [RID]))


if __name__ == "__main__":
    unittest.main()
