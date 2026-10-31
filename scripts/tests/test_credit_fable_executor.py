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
from credit_review import fable_executor as fx
_REAL_CODED_OUTCOME_REFUSAL = fx.coded_outcome_refusal
fx.coded_outcome_refusal = lambda tray, row, outcomes: None   # pinned for real in CodedOutcomeTest  # noqa: E402

RID = "11111111-1111-4111-8111-111111111111"
RID2 = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 10, 28, 22, 0, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow", ("no account-level signal",), {"decision": "allow"})


def facts(**over) -> fx.Facts:
    base = dict(status="unverified", user_id=42, popularity=30, deleted=False,
                rules={"reject_publisher_label_credit": 100.0}, metadata_source="industry", paid=True,
                profile_id="p1", owns_profile=False)
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
               "rows": [{"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3",
                         "rule": "reject_publisher_label_credit", "paid": False},
                        {"request_id": RID2, "user_id": "7", "coded_outcome": "decisions:1", "ruling_id": "u10k-3",
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

    def test_only_reject_and_approve_actions_are_executable(self):
        for action in ("delete", "merge", None):
            with self.assertRaisesRegex(fx.TrayError, "not executable"):
                fx.load_tray(self.write(self.tray(action=action)))
        # an approve tray citing a validator reject_* rule is refused (approvals cite a Fable rule + evidence)
        with self.assertRaisesRegex(fx.TrayError, "never a reject_"):
            fx.load_tray(self.write(self.tray(action="approve")))

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
            "request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "forged-ab12cd34", "rule": "R-FRAUD-DOC",
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
        kw.setdefault("sleep", lambda s: None)          # read-back retries never sleep in tests
        return fx.run(tray, apply=apply, facts_fn=lambda ids: {i: fm[i] for i in ids if i in fm},
                      gate_fn=lambda u: gate, writer=writer or write, readback=kw.pop("readback", readback),
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
        # Fable [key=executor-one-put-per-user]: 150 rows of ONE user = ONE PUT of 100; the other 50 wait a day
        seen = []
        res = self.go(self.tray(n=150, cap=400), between_batches=lambda rows, since: seen.append(len(rows)))
        self.assertEqual([len(c[0]) for c in self.calls], [100])
        self.assertEqual(seen, [100])
        self.assertEqual((res.written, res.refused), (100, {"user_rows_over_room_wait_for_another_day": 50}))
        # two users: one PUT each, and the fan-out check runs between them
        self.calls.clear()
        rows = tuple(fx.TrayRow(f"{i:08d}-2222-4222-8222-222222222222", 7 if i < 3 else 8, "u10k-3",
                                "reject_publisher_label_credit", True) for i in range(5))
        fm = {r.request_id: facts(user_id=r.user_id) for r in rows}
        seen.clear()
        res = self.go(fx.Tray("t2.json", "1" * 64, "reject", "unverified", rows, 400, None), facts_map=fm,
                      between_batches=lambda moved, since: seen.append(sorted({u for _, u, _ in moved})))
        self.assertEqual([len(c[0]) for c in self.calls], [3, 2])
        self.assertEqual(seen, [[7], [8]])

    def test_a_fanout_surprise_stops_after_that_batch(self):
        res = self.go(self.tray(n=150, cap=400), between_batches=lambda rows, since: "2 notes for user 42")
        self.assertEqual(len(self.calls), 1)
        self.assertIn("fan-out", res.stopped)


class ProfileClaimGuardTest(unittest.TestCase):
    """Batch0 incident 2026-10-29 (880d34b3): never reject a row whose submitter holds a processed claim on the
    profile (Fable monitor 03:28Z: label-credits APPROVE population); unread = refused."""

    def test_owned_profile_is_refused(self):
        self.assertEqual(fx.refusal(row(), facts(owns_profile=True), ALLOW, "unverified"),
                         "submitter_has_claim_on_profile")

    def test_unread_ownership_is_refused(self):
        self.assertEqual(fx.refusal(row(), facts(owns_profile=None), ALLOW, "unverified"), "profile_claim_unknown")

    def test_not_owned_passes(self):
        self.assertIsNone(fx.refusal(row(), facts(owns_profile=False), ALLOW, "unverified"))

    def test_fetch_facts_reads_the_ownership_column(self):
        line = ('"%s","unverified","42","30","p1","false","{}","industry","true","%s"')
        for raw, want in (("true", True), ("false", False), ("", None)):
            f = fx.fetch_facts([RID], run=lambda sql, raw=raw: line % (RID, raw))[RID.lower()]
            self.assertIs(f.owns_profile, want)
        with self.assertRaisesRegex(RuntimeError, "expected 10"):
            fx.fetch_facts([RID], run=lambda sql: '"%s","unverified","42","30","p1","false","{}","industry","true"' % RID)

    def test_sql_checks_processed_claims_on_the_profile(self):
        seen = {}
        fx.fetch_facts([RID], run=lambda sql: seen.setdefault("sql", sql) and "")
        self.assertIn("postgresql_core.public.claiming", seen["sql"])
        self.assertIn("c.userid = cr.userid", seen["sql"])
        self.assertIn("c.deletedat is null", seen["sql"])
        # ANY live claim (Fable batch0-wrong-action (3)): no status filter on the claim
        sub = seen["sql"][seen["sql"].index("public.claiming"):]
        self.assertNotIn("c.status", sub[:400])


class ReadbackLagTest(RunTest):
    """2026-10-29 03:50Z: the write landed but the first read-back trailed the primary by ~1 s."""

    def test_a_lagging_readback_is_retried_not_reported_not_moved(self):
        reads = {"n": 0}

        def lagging(status, ids):
            reads["n"] += 1
            return set(ids) if reads["n"] >= 3 else set()
        res = self.go(self.tray(n=2), readback=lagging, sleep=lambda s: None)
        self.assertEqual((res.written, res.not_moved, res.stopped), (2, 0, ""))
        self.assertEqual(reads["n"], 3)

    def test_a_row_that_never_lands_is_still_not_moved_after_the_retries(self):
        reads = {"n": 0}

        def never(status, ids):
            reads["n"] += 1
            return set()
        res = self.go(self.tray(n=1), readback=never, sleep=lambda s: None, readback_tries=4)
        self.assertEqual((res.written, res.not_moved, reads["n"]), (0, 1, 4))
        self.assertIn("not moved", res.stopped)


class QaFixTest(RunTest):
    """QA NO-GO on f5ec0da0: per-batch fresh guards, cap lock, audit before PUT; plus the junk-b1 DSP anchor guard."""

    def test_facts_and_gate_are_re_read_for_every_batch(self):
        t = self.tray(n=150, cap=400)
        late = t.rows[120].request_id
        t = fx.Tray(t.path, t.sha256, "reject", "unverified",
                    tuple(fx.TrayRow(r.request_id, 42 if i < 100 else 43, r.ruling_id, r.rule, r.paid)
                          for i, r in enumerate(t.rows)), 400, None)
        calls = {"facts": 0}

        def facts_fn(ids):
            calls["facts"] += 1
            # after batch 1 wrote, row 120 turned big: the second batch must see it
            uid = {r.request_id: r.user_id for r in t.rows}
            return {i: (facts(popularity=80, user_id=uid[i]) if (i == late and calls["facts"] > 1)
                        else facts(user_id=uid[i])) for i in ids}
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
            {"request_id": RID2, "user_id": 9, "coded_outcome": "decisions:1", "ruling_id": "junk-b1", "rule": "reject_x", "paid": False},
            {"request_id": RID, "user_id": 1, "coded_outcome": "decisions:1", "ruling_id": "junk-b1", "rule": "reject_x", "paid": True}]}
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
        self.assertEqual(written, [rows[0].request_id, rows[1].request_id])   # both paid rows, rulings A + B
        self.assertEqual([c[2] for c in self.calls], ["user:42"])             # ONE PUT for the user (all rulings)
        self.assertIn("daily cap", res.stopped)

    def test_an_evidence_recheck_tray_refuses_a_row_whose_user_answered_since(self):
        """QA #1536: a coded close whose evidence can change re-reads it per batch at write time."""
        base = self.tray()
        t = fx.Tray(base.path, base.sha256, "reject", "unverified", base.rows, 100, None,
                    recheck_evidence="no_proof_after_ask")
        first, second = (r.request_id for r in base.rows)
        seen = []

        def evidence(rows):
            seen.append([r.request_id for r in rows])
            return {first: "replied_after_ask:intercom_reply:7", second: ""}
        res = self.go(t, evidence_fn=evidence)
        self.assertEqual(res.written, 1)
        self.assertEqual(self.calls[0][0], [second])
        self.assertEqual(res.refused, {"evidence_changed": 1})
        self.assertIn("evidence_changed:replied_after_ask:intercom_reply:7",
                      [l.get("reason") for l in self.audit_lines() if l["outcome"] == "refused"])
        self.assertTrue(seen)
        self.calls.clear()
        Path(self.audit).unlink()                                           # a fresh day for this user
        dry = self.go(t, apply=False, evidence_fn=lambda rows: {})            # unreadable -> refused, never written
        self.assertEqual(dry.refused, {"evidence_changed": 2, "would_write": 0})

    def test_a_tray_without_the_flag_never_calls_the_evidence_reader(self):
        res = self.go(self.tray(), evidence_fn=lambda rows: self.fail("must not be called"))
        self.assertEqual(res.written, 2)

    def test_the_boundary_rechecks_evidence_too(self):
        doc = {"action": "reject", "expected_status": "unverified", "recheck_evidence": "no_proof_after_ask",
               "rows": [{"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3",
                         "rule": "reject_publisher_label_credit"}]}
        p = self.tmp / "tray-ev.json"
        p.write_text(json.dumps(doc))
        sha = fx.load_tray(str(p)).sha256
        self._reserve(sha)
        kw = dict(facts_fn=lambda xs: {x: facts() for x in xs}, gate_fn=lambda u: ALLOW, anchor_fn=lambda xs: {},
                  audit_path=self.audit, now=lambda: NOW)
        self.assertIsNone(fx.verify_batch(str(p), "u10k-3", "run1", [RID], "unverified",
                                          evidence_fn=lambda rows: {RID: ""}, **kw))
        self.assertIn("evidence_changed:proof_on_file",
                      fx.verify_batch(str(p), "u10k-3", "run1", [RID], "unverified",
                                      evidence_fn=lambda rows: {RID: "proof_on_file:proof_intake"}, **kw))

    def test_recheck_evidence_is_validated_and_close_only(self):
        for bad, want in (("whatever", "must be one of"), (True, "must be one of")):
            doc = {"action": "reject", "expected_status": "unverified", "recheck_evidence": bad, "rows": [
                {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3",
                 "rule": "reject_publisher_label_credit"}]}
            p = self.tmp / "bad.json"
            p.write_text(json.dumps(doc))
            with self.assertRaisesRegex(fx.TrayError, want):
                fx.load_tray(str(p))

    # ── Fable [key=executor-one-put-per-user] ──
    def test_n_rows_for_one_user_are_one_put_and_one_notice(self):
        """n1: user 161334 got 4 rejection emails (core's transition notice fires per PUT). N rows of one user ->
        ONE PUT (the fan-out read counts one notice), whatever their rulings."""
        rows = tuple(fx.TrayRow(f"{i:08d}-3333-4333-8333-333333333333", 42, f"decisions-{i}", "C5:no_proof_after_ask/v1",
                                True, "x" * 30) for i in range(4))
        notices = []
        res = self.go(fx.Tray("t.json", "2" * 64, "reject", "unverified", rows, 100, None),
                      between_batches=lambda moved, since: notices.append({u for _, u, _ in moved}) and None)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((sorted(self.calls[0][0]), self.calls[0][2]), (sorted(r.request_id for r in rows), "user:42"))
        self.assertEqual((res.written, notices), (4, [{42}]))

    def test_a_second_run_the_same_day_makes_zero_puts_for_that_user(self):
        """FINAL (Fable + r5): a user who already had a reject PUT today gets no further one - held to tomorrow's run
        with reason day_cap_user, new rows included; other users still close."""
        ids = [f"{i:08d}-4444-4444-8444-444444444444" for i in range(3)]
        first = fx.Tray("t1.json", "3" * 64, "reject", "unverified",
                        (fx.TrayRow(ids[0], 42, "u10k-3", "reject_publisher_label_credit", True),), 100, None)
        self.assertEqual(self.go(first).written, 1)
        self.calls.clear()
        later = fx.Tray("t2.json", "4" * 64, "reject", "unverified",
                        (fx.TrayRow(ids[1], 42, "u10k-3", "reject_publisher_label_credit", True),
                         fx.TrayRow(ids[2], 7, "u10k-3", "reject_publisher_label_credit", True)), 100, None)
        fm = {ids[1]: facts(), ids[2]: facts(user_id=7)}
        res = self.go(later, facts_map=fm)
        self.assertEqual([c[0] for c in self.calls], [[ids[2]]])          # 0 PUTs for user 42, user 7 closes
        self.assertEqual(res.refused, {"day_cap_user": 1})
        self.assertIn("day_cap_user", [l.get("reason") for l in self.audit_lines() if l["outcome"] == "refused"])
        self.calls.clear()
        self.assertEqual(self.go(later, facts_map=fm, apply=False).refused, {"day_cap_user": 2, "would_write": 0})

    def test_the_fanout_check_runs_on_the_batch_that_reaches_the_cap(self):
        """QA #1553: 3 eligible rows, room 2 -> the PUT closes 2; the fan-out read of THAT batch still runs and a
        surprise there is what the run reports."""
        with open(self.audit, "w") as fh:
            for i in range(98):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "old", "outcome": "written",
                                     "request_id": f"o{i}", "user_id": 1000 + i}) + "\n")
        seen = []
        res = self.go(self.tray(n=3), between_batches=lambda rows, since: seen.append(len(rows)) or "2 notes for user 42")
        self.assertEqual((len(self.calls), seen), (1, [2]))
        self.assertIn("fan-out", res.stopped)
        self.calls.clear()
        Path(self.audit).unlink()
        with open(self.audit, "w") as fh:
            for i in range(98):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "old", "outcome": "written",
                                     "request_id": f"o{i}", "user_id": 1000 + i}) + "\n")
        res = self.go(self.tray(n=3), between_batches=lambda rows, since: None)
        self.assertIn("daily cap", res.stopped)                            # clean fan-out -> the cap stop

    def test_the_boundary_counts_an_earlier_batch_of_the_same_run(self):
        """QA #1553: a second wrapper call in the SAME run for another row of a user already PUT today is refused."""
        doc = {"action": "reject", "expected_status": "unverified", "rows": [
            {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3",
             "rule": "reject_publisher_label_credit"},
            {"request_id": RID2, "user_id": 42, "coded_outcome": "decisions:2", "ruling_id": "u10k-3",
             "rule": "reject_publisher_label_credit"}]}
        p = self.tmp / "same-run.json"
        p.write_text(json.dumps(doc))
        sha = fx.load_tray(str(p)).sha256
        kw = dict(facts_fn=lambda xs: {x: facts() for x in xs}, gate_fn=lambda u: ALLOW, anchor_fn=lambda xs: {},
                  audit_path=self.audit, now=lambda: NOW)
        self._reserve(sha)
        self.assertIsNone(fx.verify_batch(str(p), "u10k-3", "run1", [RID], "unverified", **kw))
        with open(self.audit, "a") as fh:
            fh.write(json.dumps({"ts": "2026-10-28T21:58:30Z", "run_id": "run1", "outcome": "written",
                                 "request_id": RID, "user_id": 42}) + "\n")
        self._reserve(sha, rid=RID2)
        self.assertIn("day_cap_user", fx.verify_batch(str(p), "u10k-3", "run1", [RID2], "unverified", **kw))

    def test_paid_first_holds_across_users_at_the_cap(self):
        """QA #1553: [user 42 paid, user 7 paid, user 42 free] with room 2 closes 42-paid and 7-paid; 42-free waits."""
        with open(self.audit, "w") as fh:
            for i in range(98):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "old", "outcome": "written",
                                     "request_id": f"o{i}", "user_id": 1000 + i}) + "\n")
        ids = [f"{i:08d}-5555-4555-8555-555555555555" for i in range(3)]
        rows = (fx.TrayRow(ids[0], 42, "u10k-3", "reject_publisher_label_credit", True),
                fx.TrayRow(ids[1], 7, "u10k-3", "reject_publisher_label_credit", True),
                fx.TrayRow(ids[2], 42, "u10k-3", "reject_publisher_label_credit", False))
        fm = {ids[0]: facts(), ids[1]: facts(user_id=7), ids[2]: facts()}
        res = self.go(fx.Tray("t.json", "5" * 64, "reject", "unverified", rows, 100, None), facts_map=fm)
        self.assertEqual([c[0] for c in self.calls], [[ids[0]], [ids[1]]])
        self.assertEqual(res.refused, {"user_rows_over_room_wait_for_another_day": 1})
        self.assertIn("daily cap", res.stopped)

    def test_the_boundary_counts_a_not_moved_attempt_of_the_same_request(self):
        """QA #1553: an earlier same-day PUT that left request X not_moved still counts when X is re-reserved."""
        path, sha = self._tray_file()
        with open(self.audit, "w") as fh:
            fh.write(json.dumps({"ts": "2026-10-28T21:50:00Z", "run_id": "run0", "outcome": "not_moved",
                                 "request_id": RID, "user_id": 42}) + "\n")
        self._reserve(sha)
        self.assertIn("day_cap_user", self._verify(path, [RID]))

    def test_a_crash_after_the_put_still_counts_as_the_users_put_today(self):
        """QA #1553: a run killed after its PUT but before the final audit line leaves only 'reserved'; a later run
        must treat that as the user's PUT today (day_cap_user), and the boundary must not count its OWN batch."""
        with open(self.audit, "w") as fh:
            fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "crashed", "outcome": "reserved",
                                 "request_id": "older-row", "user_id": 42, "action": "reject"}) + "\n")
        res = self.go(self.tray(n=2))
        self.assertEqual((self.calls, res.refused), ([], {"day_cap_user": 2}))
        # the boundary: this batch's own reservation (with its user id) is not an earlier attempt
        Path(self.audit).unlink()
        path, sha = self._tray_file()
        with open(self.audit, "w") as fh:
            fh.write(json.dumps({"ts": "2026-10-28T21:58:00Z", "run_id": "run1", "outcome": "reserved",
                                 "request_id": RID, "user_id": 42, "tray_sha256": sha}) + "\n")
        self.assertIsNone(self._verify(path, [RID]))
        with open(self.audit, "a") as fh:            # ...but another run's reservation for the same user is
            fh.write(json.dumps({"ts": "2026-10-28T21:57:00Z", "run_id": "run0", "outcome": "reserved",
                                 "request_id": RID2, "user_id": 42}) + "\n")
        self.assertIn("day_cap_user", self._verify(path, [RID]))

    def test_an_ineligible_row_ahead_never_burns_a_slot(self):
        """QA #1553: [42 paid (rule no longer fires), 7 paid (eligible), 42 free (eligible)] with room 2 - the
        ineligible row takes no slot, so 7-paid AND 42-free both close (one PUT each)."""
        with open(self.audit, "w") as fh:
            for i in range(98):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "old", "outcome": "written",
                                     "request_id": f"o{i}", "user_id": 1000 + i}) + "\n")
        ids = [f"{i:08d}-6666-4666-8666-666666666666" for i in range(3)]
        rows = (fx.TrayRow(ids[0], 42, "u10k-3", "reject_publisher_label_credit", True),
                fx.TrayRow(ids[1], 7, "u10k-3", "reject_publisher_label_credit", True),
                fx.TrayRow(ids[2], 42, "u10k-3", "reject_publisher_label_credit", False))
        fm = {ids[0]: facts(rules={}), ids[1]: facts(user_id=7), ids[2]: facts()}
        tray = fx.Tray("t.json", "6" * 64, "reject", "unverified", rows, 100, None)
        res = self.go(tray, facts_map=fm)
        self.assertEqual([c[0] for c in self.calls], [[ids[1]], [ids[2]]])  # paid 7 FIRST, then 42's free row
        self.assertEqual(res.refused.get("rule_not_firing"), 1)
        # an early stop after the first PUT leaves the PAID row written, never the free one (QA #1553)
        self.calls.clear()
        Path(self.audit).unlink()
        with open(self.audit, "w") as fh:
            for i in range(98):
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "old", "outcome": "written",
                                     "request_id": f"o{i}", "user_id": 1000 + i}) + "\n")
        res = self.go(tray, facts_map=fm, between_batches=lambda moved, since: "stop")
        self.assertEqual(([c[0] for c in self.calls], res.written), ([[ids[1]]], 1))

    def test_yesterday_and_approvals_do_not_count_as_closed_today(self):
        with open(self.audit, "w") as fh:
            fh.write(json.dumps({"ts": "2026-10-27T23:00:00Z", "run_id": "y", "outcome": "written",
                                 "request_id": "x", "user_id": 42}) + "\n")
            fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "a", "outcome": "written",
                                 "request_id": "z", "user_id": 42, "action": "approve"}) + "\n")
        self.assertEqual(fx.closed_today(self.audit, NOW, "reject"), {})
        self.assertEqual(fx.closed_today(self.audit, NOW, "approve"), {42: "2026-10-28T01:00:00Z"})

    def test_the_boundary_refuses_a_batch_spanning_users_or_a_user_ruling_for_another_user(self):
        doc = {"action": "reject", "expected_status": "unverified", "rows": [
            {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "a1-x",
             "rule": "reject_publisher_label_credit"},
            {"request_id": RID2, "user_id": 7, "coded_outcome": "decisions:2", "ruling_id": "a1-x",
             "rule": "reject_publisher_label_credit"}]}
        p = self.tmp / "two-users.json"
        p.write_text(json.dumps(doc))
        sha = fx.load_tray(str(p)).sha256
        self._reserve(sha)
        self._reserve(sha, rid=RID2)
        kw = dict(facts_fn=lambda xs: {x: facts(user_id=42 if x == RID else 7) for x in xs}, gate_fn=lambda u: ALLOW,
                  anchor_fn=lambda xs: {}, audit_path=self.audit, now=lambda: NOW)
        self.assertIn("spans several users", fx.verify_batch(str(p), "a1-x", "run1", [RID, RID2], "unverified", **kw))
        self.assertIn("not a row of user:7", fx.verify_batch(str(p), "user:7", "run1", [RID], "unverified", **kw))
        self.assertIsNone(fx.verify_batch(str(p), "user:42", "run1", [RID], "unverified", **kw))

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
            {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3", "rule": "reject_publisher_label_credit"}]}
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


APPROVE_ROW = {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "label-credits-a", "rule": "R-LABEL-ANCHOR",
               "evidence": "org-label-anchor A: DSP label line names the org; processed org claim", "paid": True}


class ApproveTrayTest(unittest.TestCase):
    """Executor PR 2: approve trays (core FABLE_RULED scope; Fable r3 [key=ddl-anchor-records-guards])."""

    def write(self, doc):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f)
        f.close()
        return f.name

    def doc(self, **over):
        d = {"action": "approve", "expected_status": "unverified", "rows": [dict(APPROVE_ROW)]}
        d.update(over)
        return d

    def test_loads_with_its_own_cap(self):
        t = fx.load_tray(self.write(self.doc()))
        self.assertEqual((t.action, t.daily_cap, fx.target_status(t)), ("approve", 50, "approved"))

    def test_rejected_is_approvable_for_the_correction(self):
        self.assertEqual(fx.load_tray(self.write(self.doc(expected_status="rejected"))).expected_status, "rejected")

    def test_refusals(self):
        for doc, msg in (
            (self.doc(expected_status="approved"), "expected_status"),
            (self.doc(daily_cap=51), "daily_cap"),
            (self.doc(refuse_if_dsp_anchor=True), "close guard"),
            (self.doc(rows=[{**APPROVE_ROW, "evidence": "short"}]), "evidence"),
            (self.doc(rows=[{**APPROVE_ROW, "ruling_id": ""}]), "ruling id"),
        ):
            with self.assertRaisesRegex(fx.TrayError, msg):
                fx.load_tray(self.write(doc))

    def test_approve_guards(self):
        r = fx.TrayRow(RID, 42, "label-credits-a", "R-LABEL-ANCHOR", True, "x" * 30)
        ok = facts(owns_profile=True, rules={"reject_publisher_label_credit": 100.0})
        self.assertIsNone(fx.approve_refusal(r, ok, ALLOW, "unverified"))      # a held claim is fine for approvals
        cases = [
            (None, ALLOW, "row_not_found"), (facts(deleted=True), ALLOW, "row_deleted"),
            (facts(status="approved"), ALLOW, "status_changed"), (facts(user_id=7), ALLOW, "user_mismatch"),
            (facts(popularity=0), ALLOW, "big_or_unknown"), (facts(popularity=60), ALLOW, "big_or_unknown"),
            (facts(metadata_source="client"), ALLOW, "big_or_unknown"),
            (facts(), account_gate.GateResult("hold", ("x",), {}), "account_gate_hold"),
            (facts(), account_gate.GateResult("allow", ("AMBER watchlist review-local",), {"decision": "allow"}),
             "watchlisted_account"),
        ]
        for f, g, want in cases:
            self.assertTrue((fx.approve_refusal(r, f, g, "unverified") or "").startswith(want), want)


class ApproveRunTest(RunTest):
    def approve_tray(self, n=2):
        rows = tuple(fx.TrayRow(f"{i:08d}-1111-4111-8111-111111111111", 42, "label-credits-a", "R-LABEL-ANCHOR",
                                True, "x" * 30) for i in range(n))
        return fx.Tray(str(self.tmp / "a.json"), "0" * 64, "approve", "unverified", rows, 50)

    def test_writes_approved_reads_back_approved_and_audits_the_action(self):
        seen = {}

        def write(ids, expected, ruling, run_id, tray_path, status="rejected"):
            seen["status"] = status
            self.calls.append((list(ids), expected, ruling))
            return {"updatedIds": ids}

        def readback(status, ids):
            seen["rb"] = status
            return set(ids)
        t = self.approve_tray()
        res = fx.run(t, apply=True, facts_fn=lambda ids: {i: facts() for i in ids}, gate_fn=lambda u: ALLOW,
                     writer=write, readback=readback, audit_path=self.audit, registry_path=self.registry,
                     kill_file=self.kill, now=lambda: NOW, lock_path=str(self.tmp / "lock"), sleep=lambda s: None)
        self.assertEqual((res.written, seen["status"], seen["rb"]), (2, "approved", "approved"))
        lines = self.audit_lines()
        self.assertTrue(all(l["action"] == "approve" for l in lines))
        self.assertTrue(all(l["after"] == "approved" for l in lines if l["outcome"] == "written"))

    def test_approve_cap_is_separate_from_the_close_cap(self):
        with open(self.audit, "w") as fh:
            for i in range(99):     # 99 closes today (no action field = close)
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "c", "outcome": "written",
                                     "request_id": f"c{i}"}) + "\n")
            for i in range(49):     # 49 approvals today
                fh.write(json.dumps({"ts": "2026-10-28T01:00:00Z", "run_id": "a", "outcome": "written",
                                     "request_id": f"a{i}", "action": "approve"}) + "\n")
        self.assertEqual(fx.writes_today(self.audit, NOW, "reject"), 99)
        self.assertEqual(fx.writes_today(self.audit, NOW, "approve"), 49)
        t = self.approve_tray(3)

        def write(ids, expected, ruling, run_id, tray_path, status="rejected"):
            self.calls.append(list(ids))
            return {"updatedIds": ids}
        res = fx.run(t, apply=True, facts_fn=lambda ids: {i: facts() for i in ids}, gate_fn=lambda u: ALLOW,
                     writer=write, readback=lambda s, ids: set(ids), audit_path=self.audit,
                     registry_path=self.registry, kill_file=self.kill, now=lambda: NOW,
                     lock_path=str(self.tmp / "lock"), sleep=lambda s: None)
        self.assertEqual(sum(len(c) for c in self.calls), 1)
        self.assertIn("daily cap", res.stopped)

    def test_boundary_uses_the_approve_guards(self):
        doc = {"action": "approve", "expected_status": "unverified", "rows": [dict(APPROVE_ROW)]}
        p = self.tmp / "approve.json"
        p.write_text(json.dumps(doc))
        sha = fx.load_tray(str(p)).sha256
        with open(self.audit, "a") as fh:
            fh.write(json.dumps({"ts": "2026-10-28T21:58:00Z", "run_id": "r1", "outcome": "reserved",
                                 "request_id": RID, "tray_sha256": sha, "action": "approve"}) + "\n")
        kw = dict(facts_fn=lambda xs: {x: facts(owns_profile=True) for x in xs}, gate_fn=lambda u: ALLOW,
                  anchor_fn=lambda xs: {}, audit_path=self.audit, now=lambda: NOW)
        self.assertIsNone(fx.verify_batch(str(p), "label-credits-a", "r1", [RID], "unverified", status="approved", **kw))
        # a close-shaped body can never ride an approve tray's reservations, nor the reverse
        self.assertIn("not what this approve tray writes",
                      fx.verify_batch(str(p), "label-credits-a", "r1", [RID], "unverified", **kw))
        kw["facts_fn"] = lambda xs: {x: facts(popularity=0) for x in xs}
        self.assertIn("big_or_unknown",
                      fx.verify_batch(str(p), "label-credits-a", "r1", [RID], "unverified", status="approved", **kw))

    def test_a_close_tray_never_authorizes_an_approval(self):
        doc = {"action": "reject", "expected_status": "unverified", "rows": [
            {"request_id": RID, "user_id": 42, "coded_outcome": "decisions:1", "ruling_id": "u10k-3", "rule": "reject_publisher_label_credit"}]}
        p = self.tmp / "close.json"
        p.write_text(json.dumps(doc))
        self.assertIn("not what this reject tray writes",
                      fx.verify_batch(str(p), "u10k-3", "r1", [RID], "unverified", status="approved",
                                      facts_fn=lambda xs: {}, gate_fn=lambda u: ALLOW, anchor_fn=lambda xs: {},
                                      audit_path=self.audit, now=lambda: NOW))


class CodedOutcomeTest(unittest.TestCase):
    """Captain 2026-10-29 16:0xZ: per-item decisions come from the coded decider; Fable ruling ids no longer admit."""

    def write(self, doc):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(doc, f)
        f.close()
        return f.name

    def doc(self, **row):
        r = {"request_id": RID, "user_id": 42, "ruling_id": "junk_proof", "rule": "C3:junk_proof/v1",
             "evidence": "every filed document is a non-evidence artifact (C3)", "coded_outcome": "decisions:7"}
        r.update(row)
        return {"action": "reject", "expected_status": "unverified", "rows": [r]}

    def test_a_row_without_a_coded_outcome_refuses_the_tray(self):
        for bad in (None, "", "forged-ab12cd34", "decisions:", "decisions:x", "dv_outcomes:", "llm_calls:3"):
            d = self.doc(coded_outcome=bad)
            if bad is None:
                del d["rows"][0]["coded_outcome"]
            with self.assertRaisesRegex(fx.TrayError, "coded-rule outcome"):
                fx.load_tray(self.write(d))

    def test_coded_rule_ids_are_accepted_as_the_rule(self):
        self.assertEqual(fx.load_tray(self.write(self.doc())).rows[0].rule, "C3:junk_proof/v1")

    def test_role_correction_is_refused_as_a_removal_class(self):
        with self.assertRaisesRegex(fx.TrayError, "refused:removal_class"):
            fx.load_tray(self.write({**self.doc(), "action": "role_correction"}))

    def test_the_outcome_must_exist_name_the_request_be_apply_and_match_the_action(self):
        t = fx.load_tray(self.write(self.doc()))
        r = t.rows[0]
        ok = {"decisions:7": {"request_id": RID.lower(), "decision": "close", "mode": "apply"}}
        self.assertIsNone(_REAL_CODED_OUTCOME_REFUSAL(t, r, ok))
        cases = [
            ({}, "coded_outcome_missing"),
            ({"decisions:7": {**ok["decisions:7"], "request_id": RID2.lower()}}, "coded_outcome_other_request"),
            ({"decisions:7": {**ok["decisions:7"], "mode": "shadow"}}, "coded_outcome_not_apply"),
            ({"decisions:7": {**ok["decisions:7"], "decision": "approve"}}, "coded_outcome_decision"),
        ]
        for outcomes, want in cases:
            self.assertTrue((_REAL_CODED_OUTCOME_REFUSAL(t, r, outcomes) or "").startswith(want), want)

    def test_ledger_outcomes_reads_the_decisions_table(self):
        import sqlite3
        d = tempfile.mkdtemp()
        db = f"{d}/ledger.sqlite3"
        con = sqlite3.connect(db)
        con.execute("create table decisions (id integer primary key, request_id text, decision text, mode text)")
        con.execute("insert into decisions values (7, ?, 'close', 'apply')", (RID.upper(),))
        con.commit()
        con.close()
        self.assertEqual(fx.ledger_outcomes(["decisions:7", "decisions:8", "junk"], path=db),
                         {"decisions:7": {"request_id": RID.lower(), "decision": "close", "mode": "apply"}})
        self.assertEqual(fx.ledger_outcomes(["decisions:7"], path=f"{d}/missing.sqlite3"), {})

    def test_dv_outcomes_admit_only_a_forged_row_for_this_request(self):
        import sqlite3
        d = tempfile.mkdtemp()
        db = f"{d}/doc-verify.sqlite"
        con = sqlite3.connect(db)
        con.execute("create table dv_outcomes (id integer primary key, request_id text, outcome text)")
        con.execute("insert into dv_outcomes values (3, ?, 'forged')", (RID,))
        con.execute("insert into dv_outcomes values (4, ?, 'unverifiable')", (RID,))
        con.commit()
        con.close()
        got = fx.ledger_outcomes(["dv_outcomes:3", "dv_outcomes:4"], path=f"{d}/none.sqlite3", dv_path=db)
        self.assertEqual(got["dv_outcomes:3"], {"request_id": RID.lower(), "decision": "close", "mode": "apply"})
        self.assertEqual(got["dv_outcomes:4"]["decision"], "none")
        t = fx.load_tray(self.write(self.doc(coded_outcome="dv_outcomes:3")))
        self.assertIsNone(_REAL_CODED_OUTCOME_REFUSAL(t, t.rows[0], got))
        t4 = fx.load_tray(self.write(self.doc(coded_outcome="dv_outcomes:4")))
        self.assertTrue(_REAL_CODED_OUTCOME_REFUSAL(t4, t4.rows[0], got).startswith("coded_outcome_decision"))


class CodedCloseEndToEndTest(RunTest):
    """The REAL coded-outcome check (no stub) through run(): a close row admits only on a decider-ledger `decisions`
    row with decision 'close', mode 'apply', for the same request (contract: data/doc-verify-build-b1/
    coded-close-row-shape.md, Fable [key=coded-close-store]). Until a producer writes such rows (b1's C3/C5 PRs),
    every close is refused: fail closed, by the captain's 16:0xZ rule (no per-item decision outside the coded decider)."""

    def setUp(self):
        super().setUp()
        import sqlite3
        self.ledger = str(self.tmp / "ledger.sqlite3")
        con = sqlite3.connect(self.ledger)
        con.execute("create table decisions (id integer primary key, request_id text, decision text, mode text)")
        con.executemany("insert into decisions values (?,?,?,?)", [
            (1, RID, "close", "apply"),        # admits RID
            (2, RID2, "close", "shadow"),      # shadow: refused
            (3, RID2, "defer", "apply"),       # not a close: refused
        ])
        con.commit()
        con.close()

    def tearDown(self):
        fx.coded_outcome_refusal = lambda tray, row, outcomes: None     # back to the module-wide stub

    def real(self):
        fx.coded_outcome_refusal = _REAL_CODED_OUTCOME_REFUSAL

    def tray_with(self, outcomes):
        rows = tuple(fx.TrayRow(rid, 42, "junk_proof", "C3:junk_proof/v1", True, "x" * 30, (), oc)
                     for rid, oc in outcomes)
        return fx.Tray(str(self.tmp / "t.json"), "0" * 64, "reject", "unverified", rows, 100)

    def go_real(self, t):
        return self.go(t, facts_map={RID: facts(), RID2: facts(user_id=42)},
                       outcome_fn=lambda ids: fx.ledger_outcomes(ids, path=self.ledger))

    def test_a_decider_close_row_admits_its_request_and_only_it(self):
        self.real()
        res = self.go_real(self.tray_with([(RID, "decisions:1")]))
        self.assertEqual(res.written, 1)
        self.assertEqual([l["coded_outcome"] for l in self.audit_lines() if l["outcome"] == "written"], ["decisions:1"])

    def test_shadow_non_close_missing_and_other_request_rows_never_write(self):
        self.real()
        res = self.go_real(self.tray_with([(RID2, "decisions:2")]))
        self.assertEqual((res.written, self.calls), (0, []))
        self.assertEqual(res.refused, {"coded_outcome_not_apply": 1})
        self.calls.clear()
        for oc, why in (("decisions:3", "coded_outcome_decision"), ("decisions:9", "coded_outcome_missing"),
                        ("decisions:1", "coded_outcome_other_request")):
            res = self.go_real(self.tray_with([(RID2, oc)]))
            self.assertEqual((res.written, list(res.refused)), (0, [why]), oc)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
